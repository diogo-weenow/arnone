/**
 * Importação de leads — processamento assíncrono de um lote. Substitui o
 * SOLEnriquecimentoBatch.
 *
 * Lê do perfil do lote (Perfil_Importacao__mdt): Record Type, Unidade de Origem,
 * matriz de campos, modo de dono e Criar_Sem_Match__c. Itera as
 * Importacao_Linha__c com Acao ATUALIZAR/CRIAR ainda não processadas:
 *
 *  - ATUALIZAR: para cada lead alvo SELECIONADO, aplica a matriz do perfil.
 *    OVERWRITE grava quando a célula tem valor; FILL_BLANK grava só quando o
 *    campo do lead está vazio E a célula tem valor; célula vazia NUNCA apaga.
 *    Campos de propriedade, status, identidade, distribuição, cadência e estado
 *    do bot STE ficam numa blocklist e nunca são gravados. O Record Type e o
 *    OwnerId nunca mudam numa atualização.
 *  - CRIAR (só se o perfil cria): lead com o Record Type e a Unidade do perfil,
 *    Company/LastName mapeados, CNPJ formatado + normalizado, Status padrão e os
 *    campos Usar_Na_Criacao__c. Sem OwnerId. Modo DISTRIBUICAO_SOL: insert
 *    simples, o flow SOL_Distribuir_Lead distribui e cria a Task "1ª Ligação".
 *    Modo REGRA_ATRIBUICAO: insert com a assignment rule Distribuicao_Por_Unidade
 *    chamada pelo Id (-> Fila_Leads_<BU>). Não usa a regra padrão: a regra ativa
 *    da org é outra (Atribuicao_Leads).
 *
 * `with sharing`: respeita o compartilhamento do usuário que submeteu o batch.
 * FLS por Security.stripInaccessible (UPDATABLE/CREATABLE): o campo sem FLS é
 * barrado sem derrubar o registro. DML com allOrNone=false. scope 50.
 *
 * Idempotência: linha com Resultado_Processamento__c preenchido é excluída no
 * start(); na criação, Lead_Resultante__c preenchido é a trava adicional.
 */
public with sharing class ImportacaoLeadsBatch implements Database.Batchable<SObject>, Database.Stateful {
  private final Id loteId;
  private final String perfilDev;
  @TestVisible
  private Acumulador acc = new Acumulador();

  public ImportacaoLeadsBatch(Id loteId) {
    this.loteId = loteId;
    List<Importacao_Lote__c> l = [
      SELECT Perfil_Importacao__c
      FROM Importacao_Lote__c
      WHERE Id = :loteId
      LIMIT 1
    ];
    this.perfilDev = l.isEmpty() ? null : l[0].Perfil_Importacao__c;
  }

  /** Contadores em nível de LINHA, carregados entre execuções (Stateful). */
  public class Acumulador {
    public Integer atualizadas = 0;
    public Integer criadas = 0;
    public Integer erros = 0;
    public List<String> mensagens = new List<String>();
  }

  /**
   * Campos que a importação NUNCA grava, ainda que mapeados por engano.
   * Comparação por API name em minúsculas.
   */
  @TestVisible
  private static final Set<String> BLOCKLIST = new Set<String>{
    'ownerid',
    'status',
    'recordtypeid',
    'isconverted',
    'company',
    'lastname',
    'cnpj__c',
    'cnpj_normalizado__c',
    'cpf__c',
    'unidade_origem__c',
    'sol_status_distribuicao__c',
    'sol_data_distribuicao__c',
    'sol_erro_distribuicao__c',
    'sol_data_inicio_ciclo_contato__c',
    'sol_status_reatribuicao__c',
    'sol_quantidade_reatribuicoes__c',
    'sol_data_ultima_reatribuicao__c',
    'sol_motivo_ultima_reatribuicao__c',
    'sol_opt_out__c',
    'sol_data_opt_out__c',
    'sol_motivo_desqualificacao__c',
    'sol_observacao_desqualificacao__c',
    'sol_contato_efetivado__c',
    'sol_data_contato_efetivado__c',
    'sol_data_primeira_ligacao__c',
    'sol_tentativas_contato__c',
    'sol_apto_conversao__c',
    'sol_status_procuracao__c',
    'sol_lead_parado__c',
    'ste_etapa_bot__c',
    'ste_etapa_bot_desde__c',
    'ste_messagingsession_id__c',
    'ste_classificacao_fila__c',
    'ste_retomadas_enviadas__c',
    'ste_retomada_1_em__c',
    'ste_retomada_2_em__c',
    'ste_retomada_3_em__c',
    'ste_etapa_notificada__c',
    'ste_telefone_e164__c',
    'ste_cpf_confirmado__c',
    'ste_cnh_enviada__c',
    'ste_data_envio_cnh__c',
    'ste_prazo_envio_cnh__c',
    'ste_motivo_desqualificacao__c'
  };

  /** Colunas de criação: protegidas na atualização, sem gerar aviso. */
  private static final Set<String> COLUNAS_CRIACAO = new Set<String>{
    'company',
    'lastname'
  };

  private static Map<String, Id> rtCache = new Map<String, Id>();
  private static Id recordTypeId(String developerName) {
    if (!rtCache.containsKey(developerName)) {
      Schema.RecordTypeInfo info = Lead.SObjectType.getDescribe()
        .getRecordTypeInfosByDeveloperName()
        .get(developerName);
      if (info == null) {
        throw new ImportacaoLeadsController.ImportacaoException(
          'Record Type ' + developerName + ' não encontrado no Lead.'
        );
      }
      rtCache.put(developerName, info.getRecordTypeId());
    }
    return rtCache.get(developerName);
  }

  /** Nome da assignment rule de Lead usada no modo REGRA_ATRIBUICAO. */
  @TestVisible
  private static String regraAtribuicaoNome = 'Distribuicao_Por_Unidade';

  private static Id regraCache;
  private static Id regraAtribuicaoId() {
    if (regraCache == null) {
      List<AssignmentRule> r = [
        SELECT Id
        FROM AssignmentRule
        WHERE SobjectType = 'Lead' AND Name = :regraAtribuicaoNome
        LIMIT 1
      ];
      if (r.isEmpty()) {
        throw new ImportacaoLeadsController.ImportacaoException(
          'Assignment rule de Lead "' +
            regraAtribuicaoNome +
            '" não encontrada; o modo REGRA_ATRIBUICAO não pode criar leads.'
        );
      }
      regraCache = r[0].Id;
    }
    return regraCache;
  }

  private static String statusCache;
  private static String statusFunilPadrao() {
    if (statusCache == null) {
      List<LeadStatus> p = [
        SELECT MasterLabel
        FROM LeadStatus
        WHERE IsDefault = TRUE
        LIMIT 1
      ];
      statusCache = p.isEmpty() ? 'Novo' : p[0].MasterLabel;
    }
    return statusCache;
  }

  // ==================================================================
  //  Batchable
  // ==================================================================

  public Database.QueryLocator start(Database.BatchableContext bc) {
    Id lid = loteId;
    return Database.getQueryLocator(
      [
        SELECT
          Id,
          Numero_Linha__c,
          Chave_Original__c,
          Chave_Normalizada__c,
          Payload_JSON__c,
          Resultado_Match__c,
          Acao__c,
          Leads_Alvo__c,
          Lead_Resultante__c
        FROM Importacao_Linha__c
        WHERE
          Lote__c = :lid
          AND Acao__c IN ('ATUALIZAR', 'CRIAR')
          AND Resultado_Processamento__c = NULL
      ]
    );
  }

  public void execute(
    Database.BatchableContext bc,
    List<Importacao_Linha__c> escopo
  ) {
    processarEscopo(escopo, acc, perfilDev);
  }

  public void finish(Database.BatchableContext bc) {
    try {
      Integer ignorados = [
        SELECT COUNT()
        FROM Importacao_Linha__c
        WHERE Lote__c = :loteId AND Acao__c = 'IGNORAR'
      ];

      Importacao_Lote__c lote = [
        SELECT Id, Mensagens__c
        FROM Importacao_Lote__c
        WHERE Id = :loteId
        LIMIT 1
      ];
      lote.Qtd_Atualizados__c = acc.atualizadas;
      lote.Qtd_Criados__c = acc.criadas;
      lote.Qtd_Erros__c = acc.erros;
      lote.Qtd_Ignorados__c = ignorados;
      lote.Data_Processamento__c = System.now();
      lote.AsyncApexJobId__c = String.valueOf(bc.getJobId());
      lote.Status__c = acc.erros > 0 ? 'Concluído com erros' : 'Concluído';

      String resumo =
        'Processado em ' +
        System.now().format() +
        '. Atualizados: ' +
        acc.atualizadas +
        ' linha(s); Criados: ' +
        acc.criadas +
        '; Ignorados: ' +
        ignorados +
        '; Erros: ' +
        acc.erros +
        '.';
      List<String> partes = new List<String>();
      if (String.isNotBlank(lote.Mensagens__c)) {
        partes.add(lote.Mensagens__c);
      }
      partes.add(resumo);
      for (Integer i = 0; i < acc.mensagens.size() && i < 50; i++) {
        partes.add(acc.mensagens[i]);
      }
      lote.Mensagens__c = String.join(partes, '\n').abbreviate(131072);
      update lote;
    } catch (Exception e) {
      System.debug(
        LoggingLevel.ERROR,
        'ImportacaoLeadsBatch.finish: ' + e.getTypeName() + ': ' + e.getMessage()
      );
    }
  }

  // ==================================================================
  //  Núcleo (testável diretamente sob System.runAs para validar FLS)
  // ==================================================================

  @TestVisible
  public static void processarEscopo(
    List<Importacao_Linha__c> escopo,
    Acumulador acc,
    String perfilDeveloperName
  ) {
    Perfil_Importacao__mdt perfil = ImportacaoLeadsController.perfil(
      perfilDeveloperName
    );
    Map<String, Perfil_Importacao_Campo__mdt> matriz = ImportacaoLeadsController.matrizPorCampo(
      perfil.DeveloperName
    );
    Map<String, Schema.SObjectField> camposLead = Schema.SObjectType.Lead.fields.getMap();

    List<Importacao_Linha__c> aAtualizar = new List<Importacao_Linha__c>();
    List<Importacao_Linha__c> aCriar = new List<Importacao_Linha__c>();
    List<Importacao_Linha__c> naoCriar = new List<Importacao_Linha__c>();
    for (Importacao_Linha__c l : escopo) {
      if (l.Lead_Resultante__c != null) {
        continue;
      }
      if (l.Acao__c == 'ATUALIZAR') {
        aAtualizar.add(l);
      } else if (l.Acao__c == 'CRIAR') {
        // Perfil que não cria (ex.: STE) nunca cria, mesmo com linha CRIAR.
        if (
          perfil.Criar_Sem_Match__c == true &&
          perfil.Chave_Casamento__c == ImportacaoLeadsDocumento.CHAVE_CNPJ
        ) {
          aCriar.add(l);
        } else {
          l.Acao__c = 'IGNORAR';
          l.Resultado_Processamento__c = 'Ignorado: este perfil não cria leads';
          naoCriar.add(l);
        }
      }
    }

    processarAtualizacoes(aAtualizar, matriz, camposLead, acc);
    processarCriacoes(aCriar, perfil, matriz, camposLead, acc);

    List<Importacao_Linha__c> todas = new List<Importacao_Linha__c>();
    todas.addAll(aAtualizar);
    todas.addAll(aCriar);
    todas.addAll(naoCriar);
    if (!todas.isEmpty()) {
      update todas;
    }
  }

  // ------------------------------------------------------------------ ATUALIZAR

  private static void processarAtualizacoes(
    List<Importacao_Linha__c> linhas,
    Map<String, Perfil_Importacao_Campo__mdt> matriz,
    Map<String, Schema.SObjectField> camposLead,
    Acumulador acc
  ) {
    if (linhas.isEmpty()) {
      return;
    }

    Map<Id, List<Id>> alvosPorLinha = new Map<Id, List<Id>>();
    Set<Id> todosIds = new Set<Id>();
    Set<String> camposUsados = new Set<String>();
    for (Importacao_Linha__c l : linhas) {
      List<Id> sel = idsSelecionados(l);
      alvosPorLinha.put(l.Id, sel);
      todosIds.addAll(sel);
      for (String campo : ImportacaoLeadsController.payloadDe(l.Payload_JSON__c).keySet()) {
        if (campoAtualizavel(campo, matriz, camposLead)) {
          camposUsados.add(
            camposLead.get(campo.toLowerCase()).getDescribe().getName()
          );
        }
      }
    }

    Map<Id, Lead> originais = new Map<Id, Lead>();
    if (!todosIds.isEmpty() && !camposUsados.isEmpty()) {
      originais = consultarLeads(todosIds, camposUsados);
    } else if (!todosIds.isEmpty()) {
      originais = new Map<Id, Lead>(
        [SELECT Id FROM Lead WHERE Id IN :todosIds WITH USER_MODE]
      );
    }

    Map<Id, Lead> paraUpdate = new Map<Id, Lead>();
    Map<Id, Map<String, Object>> efetivo = new Map<Id, Map<String, Object>>();
    Map<Id, Integer> tocadosPorLinha = new Map<Id, Integer>();
    Map<Id, List<String>> errosPorLinha = new Map<Id, List<String>>();
    Map<Id, Set<Id>> leadsDaLinha = new Map<Id, Set<Id>>();

    for (Importacao_Linha__c l : linhas) {
      Map<String, String> valores = ImportacaoLeadsController.payloadDe(
        l.Payload_JSON__c
      );
      List<String> erros = new List<String>();
      Integer tocados = 0;
      Set<Id> leadsDesta = new Set<Id>();

      for (String campoBruto : valores.keySet()) {
        String lower = campoBruto.toLowerCase();
        // Company/LastName são as colunas de criação, enviadas em toda linha:
        // ignorá-las na atualização é o esperado, não um aviso ao operador.
        if (BLOCKLIST.contains(lower) && !COLUNAS_CRIACAO.contains(lower)) {
          erros.add('Campo protegido ignorado: ' + campoBruto);
        }
      }

      for (Id leadId : alvosPorLinha.get(l.Id)) {
        Lead orig = originais.get(leadId);
        if (orig == null) {
          erros.add('Lead ' + leadId + ' não encontrado ou sem acesso.');
          continue;
        }
        leadsDesta.add(leadId);
        if (!efetivo.containsKey(leadId)) {
          efetivo.put(leadId, new Map<String, Object>());
          for (String c : camposUsados) {
            efetivo.get(leadId).put(c, orig.get(c));
          }
        }
        Lead alvo = paraUpdate.containsKey(leadId)
          ? paraUpdate.get(leadId)
          : new Lead(Id = leadId);
        Boolean mudou = false;

        for (String campoBruto : valores.keySet()) {
          if (!campoAtualizavel(campoBruto, matriz, camposLead)) {
            continue;
          }
          Schema.SObjectField f = camposLead.get(campoBruto.toLowerCase());
          String campo = f.getDescribe().getName();
          String raw = valores.get(campoBruto);
          if (String.isBlank(raw)) {
            continue; // célula vazia NUNCA grava nem apaga.
          }
          Perfil_Importacao_Campo__mdt mdt = matriz.get(campo) == null
            ? matriz.get(campoBruto)
            : matriz.get(campo);
          Object convertido;
          try {
            convertido = converter(
              raw,
              mdt == null ? 'TEXT' : mdt.Tipo_Conversao__c,
              f
            );
          } catch (Exception ce) {
            erros.add('Campo ' + campo + ': valor inválido "' + raw + '".');
            continue;
          }
          String politica = (mdt == null || String.isBlank(mdt.Politica__c))
            ? 'OVERWRITE'
            : mdt.Politica__c;
          Object atual = efetivo.get(leadId).get(campo);
          if (politica == 'FILL_BLANK' && !vazio(atual)) {
            continue; // campo já tem valor: FILL_BLANK não sobrescreve.
          }
          alvo.put(campo, convertido);
          efetivo.get(leadId).put(campo, convertido);
          mudou = true;
        }

        if (mudou) {
          paraUpdate.put(leadId, alvo);
          tocados++;
        }
      }
      tocadosPorLinha.put(l.Id, tocados);
      errosPorLinha.put(l.Id, erros);
      leadsDaLinha.put(l.Id, leadsDesta);
    }

    // FLS por campo via stripInaccessible + DML parcial (allOrNone=false).
    Set<Id> leadsComFalha = new Set<Id>();
    if (!paraUpdate.isEmpty()) {
      List<Lead> upd = paraUpdate.values();
      List<Id> updIds = new List<Id>();
      for (Lead l : upd) {
        updIds.add(l.Id);
      }
      SObjectAccessDecision d = Security.stripInaccessible(
        AccessType.UPDATABLE,
        upd
      );
      Database.SaveResult[] srs = Database.update(d.getRecords(), false);
      for (Integer i = 0; i < srs.size(); i++) {
        if (!srs[i].isSuccess()) {
          leadsComFalha.add(updIds[i]);
          acc.mensagens.add(
            'Lead ' + updIds[i] + ': ' + mensagemErro(srs[i].getErrors())
          );
        }
      }
    }

    for (Importacao_Linha__c l : linhas) {
      List<String> erros = errosPorLinha.get(l.Id);
      Integer tocados = tocadosPorLinha.get(l.Id);
      Integer falhas = 0;
      for (Id leadId : leadsDaLinha.get(l.Id)) {
        if (leadsComFalha.contains(leadId)) {
          falhas++;
          erros.add('Falha ao gravar o Lead ' + leadId + '.');
        }
      }
      // Só lead com mudança vai ao DML, então toda falha saiu de "tocados".
      Integer sucesso = tocados - falhas;
      if (falhas > 0 && sucesso <= 0) {
        l.Resultado_Processamento__c = 'ERRO';
        acc.erros++;
      } else if (sucesso > 0) {
        l.Resultado_Processamento__c = 'Atualizado: ' + sucesso + ' Lead(s)';
        acc.atualizadas++;
      } else {
        l.Resultado_Processamento__c = 'Sem alteração';
      }
      l.Erro__c = erros.isEmpty()
        ? null
        : String.join(erros, ' | ').abbreviate(32000);
    }
  }

  // ------------------------------------------------------------------ CRIAR

  private static void processarCriacoes(
    List<Importacao_Linha__c> linhas,
    Perfil_Importacao__mdt perfil,
    Map<String, Perfil_Importacao_Campo__mdt> matriz,
    Map<String, Schema.SObjectField> camposLead,
    Acumulador acc
  ) {
    if (linhas.isEmpty()) {
      return;
    }
    Id rt = recordTypeId(perfil.Record_Type__c);
    String statusInicial = statusFunilPadrao();

    List<Lead> novos = new List<Lead>();
    List<Importacao_Linha__c> linhasCriar = new List<Importacao_Linha__c>();
    List<List<String>> errosCriar = new List<List<String>>();

    for (Importacao_Linha__c l : linhas) {
      Map<String, String> valores = ImportacaoLeadsController.payloadDe(
        l.Payload_JSON__c
      );
      String company = valores.get('Company');
      String lastName = valores.get('LastName');
      String norm = l.Chave_Normalizada__c;
      if (
        String.isBlank(company) ||
        String.isBlank(lastName) ||
        !ImportacaoLeadsDocumento.cnpjValido(norm)
      ) {
        l.Resultado_Processamento__c = 'ERRO';
        l.Erro__c = 'Sem Company/LastName ou CNPJ inválido — não criado.';
        acc.erros++;
        continue;
      }

      Lead nova = new Lead(
        RecordTypeId = rt,
        Unidade_Origem__c = perfil.Unidade_Origem__c,
        Company = company.abbreviate(255),
        LastName = lastName.abbreviate(80),
        CNPJ__c = ImportacaoLeadsDocumento.formatarCnpj(norm),
        CNPJ_Normalizado__c = norm,
        Status = statusInicial
      );

      List<String> erros = new List<String>();
      for (String campoBruto : valores.keySet()) {
        Schema.SObjectField f = camposLead.get(campoBruto.toLowerCase());
        if (f == null) {
          continue;
        }
        String campo = f.getDescribe().getName();
        if (BLOCKLIST.contains(campo.toLowerCase())) {
          continue; // Company/LastName/RT/CNPJ já setados; protegidos fora.
        }
        Perfil_Importacao_Campo__mdt mdt = matriz.get(campo);
        if (mdt == null || mdt.Usar_Na_Criacao__c != true) {
          continue;
        }
        String raw = valores.get(campoBruto);
        if (String.isBlank(raw)) {
          continue;
        }
        try {
          nova.put(campo, converter(raw, mdt.Tipo_Conversao__c, f));
        } catch (Exception ce) {
          erros.add('Campo ' + campo + ': valor inválido "' + raw + '".');
        }
      }

      novos.add(nova);
      linhasCriar.add(l);
      errosCriar.add(erros);
    }

    if (novos.isEmpty()) {
      return;
    }

    SObjectAccessDecision d = Security.stripInaccessible(
      AccessType.CREATABLE,
      novos
    );
    List<SObject> stripped = d.getRecords();
    Database.SaveResult[] srs;
    if (perfil.Modo_Dono__c == ImportacaoLeadsController.MODO_REGRA_ATRIBUICAO) {
      // Dono pela regra Distribuicao_Por_Unidade, chamada pelo Id: a regra
      // padrão (ativa) da org é outra. O Id aceita regra ativa ou inativa.
      Id regraId;
      try {
        regraId = regraAtribuicaoId();
      } catch (ImportacaoLeadsController.ImportacaoException e) {
        for (Importacao_Linha__c l : linhasCriar) {
          l.Resultado_Processamento__c = 'ERRO';
          l.Erro__c = e.getMessage();
          acc.erros++;
        }
        acc.mensagens.add(e.getMessage());
        return;
      }
      Database.DMLOptions dmo = new Database.DMLOptions();
      dmo.assignmentRuleHeader.assignmentRuleId = regraId;
      dmo.optAllOrNone = false;
      srs = Database.insert(stripped, dmo);
    } else {
      // DISTRIBUICAO_SOL: sem OwnerId; o SOL_Distribuir_Lead distribui.
      srs = Database.insert(stripped, false);
    }
    for (Integer i = 0; i < srs.size(); i++) {
      Importacao_Linha__c l = linhasCriar[i];
      List<String> erros = errosCriar[i];
      if (srs[i].isSuccess()) {
        l.Lead_Resultante__c = srs[i].getId();
        l.Resultado_Processamento__c = 'Criado';
        acc.criadas++;
      } else {
        l.Resultado_Processamento__c = 'ERRO';
        erros.add(mensagemErro(srs[i].getErrors()));
        acc.erros++;
      }
      l.Erro__c = erros.isEmpty()
        ? null
        : String.join(erros, ' | ').abbreviate(32000);
    }
  }

  // ==================================================================
  //  Helpers
  // ==================================================================

  private static Map<Id, Lead> consultarLeads(Set<Id> ids, Set<String> campos) {
    // Campos vêm do describe validado (não é input de usuário). Ids em bind.
    List<String> lista = new List<String>(campos);
    String q =
      'SELECT Id, ' +
      String.join(lista, ', ') +
      ' FROM Lead WHERE Id IN :ids';
    Map<Id, Lead> m = new Map<Id, Lead>();
    for (
      Lead l : (List<Lead>) Database.queryWithBinds(
        q,
        new Map<String, Object>{ 'ids' => ids },
        AccessLevel.USER_MODE
      )
    ) {
      m.put(l.Id, l);
    }
    return m;
  }

  private static Boolean campoAtualizavel(
    String campoBruto,
    Map<String, Perfil_Importacao_Campo__mdt> matriz,
    Map<String, Schema.SObjectField> camposLead
  ) {
    if (String.isBlank(campoBruto)) {
      return false;
    }
    String lower = campoBruto.toLowerCase();
    if (BLOCKLIST.contains(lower)) {
      return false;
    }
    Schema.SObjectField f = camposLead.get(lower);
    if (f == null) {
      return false;
    }
    String api = f.getDescribe().getName();
    // Só aplica campos que estão na matriz do perfil (por API name).
    return matriz.containsKey(api) || matriz.containsKey(campoBruto);
  }

  private static List<Id> idsSelecionados(Importacao_Linha__c l) {
    List<Id> ids = new List<Id>();
    if (String.isBlank(l.Leads_Alvo__c)) {
      return ids;
    }
    try {
      List<Object> alvos = (List<Object>) JSON.deserializeUntyped(
        l.Leads_Alvo__c
      );
      for (Object o : alvos) {
        Map<String, Object> m = (Map<String, Object>) o;
        Object sel = m.get('selecionado');
        Object id = m.get('id');
        if (id != null && (sel == null || sel == true)) {
          ids.add((Id) String.valueOf(id));
        }
      }
    } catch (Exception e) {
      // Leads_Alvo corrompido: linha segue sem alvos (resultado "sem alteração").
      System.debug(
        LoggingLevel.WARN,
        'ImportacaoLeadsBatch: Leads_Alvo inválido na linha ' + l.Id
      );
    }
    return ids;
  }

  private static Boolean vazio(Object v) {
    return v == null || String.valueOf(v) == '';
  }

  /**
   * Converte o texto da célula para o tipo do campo de Lead, usando o
   * Tipo_Conversao__c como estratégia de parse e coagindo ao tipo Apex real do
   * campo. Lança em valor inválido.
   */
  @TestVisible
  private static Object converter(
    String raw,
    String tipo,
    Schema.SObjectField f
  ) {
    String v = raw == null ? '' : raw.trim();
    Schema.DisplayType dt = f.getDescribe().getType();

    if (
      dt == Schema.DisplayType.INTEGER ||
      dt == Schema.DisplayType.DOUBLE ||
      dt == Schema.DisplayType.CURRENCY ||
      dt == Schema.DisplayType.PERCENT ||
      tipo == 'NUMBER' ||
      tipo == 'CURRENCY' ||
      tipo == 'PERCENT'
    ) {
      Decimal dec = parseDecimal(v);
      if (dt == Schema.DisplayType.INTEGER) {
        return dec.round(System.RoundingMode.HALF_UP).intValue();
      }
      return dec;
    }
    if (dt == Schema.DisplayType.DATE || tipo == 'DATE') {
      return parseDate(v);
    }
    if (dt == Schema.DisplayType.DATETIME) {
      return Datetime.valueOf(v);
    }
    if (dt == Schema.DisplayType.BOOLEAN) {
      return v.equalsIgnoreCase('true') || v == '1' || v.equalsIgnoreCase('sim');
    }
    return v; // TEXT, PICKLIST, EMAIL, PHONE, URL, etc.
  }

  private static Decimal parseDecimal(String v) {
    String s = v.replaceAll('[R\\$\\s]', '');
    if (s.contains(',') && s.contains('.')) {
      // pt-BR: ponto milhar, vírgula decimal.
      s = s.replace('.', '').replace(',', '.');
    } else if (s.contains(',')) {
      s = s.replace(',', '.');
    }
    return Decimal.valueOf(s);
  }

  private static Date parseDate(String v) {
    if (v.contains('/')) {
      List<String> p = v.split('/');
      if (p.size() == 3) {
        return Date.newInstance(
          Integer.valueOf(p[2]),
          Integer.valueOf(p[1]),
          Integer.valueOf(p[0])
        );
      }
    }
    return Date.valueOf(v); // yyyy-MM-dd
  }

  private static String mensagemErro(List<Database.Error> errs) {
    List<String> ms = new List<String>();
    for (Database.Error e : errs) {
      ms.add(e.getStatusCode() + ': ' + e.getMessage());
    }
    return String.join(ms, '; ').abbreviate(2000);
  }
}
