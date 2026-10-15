/**
 * Upload enriquecimento Lemit — processamento assíncrono de um lote.
 *
 * Itera as SOL_Enriquecimento_Linha__c do lote com Acao != IGNORAR e ainda não
 * processadas (idempotência), aplicando:
 *
 *  - ATUALIZAR: para cada Lead alvo SELECIONADO, aplica a matriz CMDT
 *    (SOL_Lemit_Mapeamento__mdt). OVERWRITE grava quando a célula tem valor;
 *    FILL_BLANK grava só quando o campo do Lead está vazio E a célula tem valor;
 *    célula vazia NUNCA apaga. Campos de propriedade/status/distribuição/
 *    cadência/opt-out/desqualificação/reatribuição ficam numa blocklist e nunca
 *    são tocados, mesmo que mapeados por engano.
 *  - CRIAR: monta Lead SOL (RecordType SOL por DeveloperName, Unidade_Origem__c
 *    'SOL', Company/LastName mapeados, CNPJ formatado + normalizado, Status
 *    inicial padrão do funil e os campos Usar_Na_Criacao__c). NÃO seta OwnerId
 *    nem status de distribuição: o insert dispara SOL_Distribuir_Lead, que
 *    distribui em round-robin e cria a Task "1ª Ligação". Sem serviço paralelo.
 *
 * `with sharing`: respeita o compartilhamento do usuário que submeteu o batch.
 * FLS de Lead é aplicada por Security.stripInaccessible (UPDATABLE na
 * atualização, CREATABLE na criação): o campo sem FLS é barrado sem derrubar o
 * registro inteiro nem lançar exceção. DML de Lead com allOrNone=false — uma
 * linha com erro não aborta o escopo. scope 50.
 *
 * Idempotência: linha com Resultado_Processamento__c preenchido é excluída já no
 * start(); na criação, Lead_Resultante__c preenchido é a trava adicional.
 * Reprocessar o mesmo lote não duplica criações.
 */
public with sharing class SOLEnriquecimentoBatch implements Database.Batchable<SObject>, Database.Stateful {
  private final Id loteId;
  @TestVisible
  private Acumulador acc = new Acumulador();

  public SOLEnriquecimentoBatch(Id loteId) {
    this.loteId = loteId;
  }

  /** Contadores em nível de LINHA, carregados entre execuções (Stateful). */
  public class Acumulador {
    public Integer atualizadas = 0;
    public Integer criadas = 0;
    public Integer erros = 0;
    public List<String> mensagens = new List<String>();
  }

  /**
   * Campos que o enriquecimento NUNCA grava numa atualização, ainda que
   * mapeados por engano na CMDT. Propriedade, status do funil, record type,
   * identidade (CNPJ), e todo o estado de distribuição/cadência/opt-out/
   * desqualificação/reatribuição. Comparação por API name em minúsculas.
   */
  private static final Set<String> BLOCKLIST = new Set<String>{
    'ownerid',
    'status',
    'recordtypeid',
    'isconverted',
    'company',
    'lastname',
    'cnpj__c',
    'sol_cnpj_normalizado__c',
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
    'sol_lead_parado__c'
  };

  private static Id rtSolCache;
  private static Id rtSol() {
    if (rtSolCache == null) {
      Schema.RecordTypeInfo info = Lead.SObjectType.getDescribe()
        .getRecordTypeInfosByDeveloperName()
        .get('SOL');
      if (info == null) {
        throw new SOLEnriquecimentoController.EnriquecimentoException(
          'Record Type SOL não encontrado no Lead.'
        );
      }
      rtSolCache = info.getRecordTypeId();
    }
    return rtSolCache;
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
          CNPJ_Original__c,
          CNPJ_Normalizado__c,
          Payload_JSON__c,
          Resultado_Match__c,
          Acao__c,
          Leads_Alvo__c,
          Lead_Resultante__c
        FROM SOL_Enriquecimento_Linha__c
        WHERE
          Lote__c = :lid
          AND Acao__c IN ('ATUALIZAR', 'CRIAR')
          AND Resultado_Processamento__c = NULL
      ]
    );
  }

  public void execute(
    Database.BatchableContext bc,
    List<SOL_Enriquecimento_Linha__c> escopo
  ) {
    processarEscopo(escopo, acc);
  }

  public void finish(Database.BatchableContext bc) {
    try {
      Integer ignorados = [
        SELECT COUNT()
        FROM SOL_Enriquecimento_Linha__c
        WHERE Lote__c = :loteId AND Acao__c = 'IGNORAR'
      ];

      SOL_Enriquecimento_Lote__c lote = [
        SELECT Id, Mensagens__c
        FROM SOL_Enriquecimento_Lote__c
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
        'SOLEnriquecimentoBatch.finish: ' +
          e.getTypeName() +
          ': ' +
          e.getMessage()
      );
    }
  }

  // ==================================================================
  //  Núcleo (testável diretamente sob System.runAs para validar FLS)
  // ==================================================================

  @TestVisible
  public static void processarEscopo(
    List<SOL_Enriquecimento_Linha__c> escopo,
    Acumulador acc
  ) {
    Map<String, SOL_Lemit_Mapeamento__mdt> matriz = SOLEnriquecimentoController.matrizPorCampo();
    Map<String, Schema.SObjectField> camposLead = Schema.SObjectType.Lead.fields.getMap();

    List<SOL_Enriquecimento_Linha__c> aAtualizar = new List<SOL_Enriquecimento_Linha__c>();
    List<SOL_Enriquecimento_Linha__c> aCriar = new List<SOL_Enriquecimento_Linha__c>();
    for (SOL_Enriquecimento_Linha__c l : escopo) {
      if (l.Acao__c == 'ATUALIZAR' && l.Lead_Resultante__c == null) {
        aAtualizar.add(l);
      } else if (l.Acao__c == 'CRIAR' && l.Lead_Resultante__c == null) {
        aCriar.add(l);
      }
    }

    processarAtualizacoes(aAtualizar, matriz, camposLead, acc);
    processarCriacoes(aCriar, matriz, camposLead, acc);

    List<SOL_Enriquecimento_Linha__c> todas = new List<SOL_Enriquecimento_Linha__c>();
    todas.addAll(aAtualizar);
    todas.addAll(aCriar);
    if (!todas.isEmpty()) {
      update todas;
    }
  }

  // ------------------------------------------------------------------ ATUALIZAR

  private static void processarAtualizacoes(
    List<SOL_Enriquecimento_Linha__c> linhas,
    Map<String, SOL_Lemit_Mapeamento__mdt> matriz,
    Map<String, Schema.SObjectField> camposLead,
    Acumulador acc
  ) {
    if (linhas.isEmpty()) {
      return;
    }

    // Ids alvo selecionados por linha + união de ids + união de campos mapeados.
    Map<Id, List<Id>> alvosPorLinha = new Map<Id, List<Id>>();
    Set<Id> todosIds = new Set<Id>();
    Set<String> camposUsados = new Set<String>();
    for (SOL_Enriquecimento_Linha__c l : linhas) {
      List<Id> sel = idsSelecionados(l);
      alvosPorLinha.put(l.Id, sel);
      todosIds.addAll(sel);
      for (String campo : payloadDe(l).keySet()) {
        if (campoAtualizavel(campo, matriz, camposLead)) {
          camposUsados.add(camposLead.get(campo.toLowerCase()).getDescribe().getName());
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

    for (SOL_Enriquecimento_Linha__c l : linhas) {
      Map<String, String> valores = payloadDe(l);
      List<String> erros = new List<String>();
      Integer tocados = 0;
      Set<Id> leadsDesta = new Set<Id>();

      for (Id leadId : alvosPorLinha.get(l.Id)) {
        Lead orig = originais.get(leadId);
        if (orig == null) {
          erros.add('Lead ' + leadId + ' não encontrado.');
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
            if (BLOCKLIST.contains(campoBruto.toLowerCase())) {
              erros.add('Campo protegido ignorado: ' + campoBruto);
            }
            continue;
          }
          Schema.SObjectField f = camposLead.get(campoBruto.toLowerCase());
          String campo = f.getDescribe().getName();
          String raw = valores.get(campoBruto);
          if (String.isBlank(raw)) {
            continue; // célula vazia NUNCA grava nem apaga.
          }
          SOL_Lemit_Mapeamento__mdt mdt = matriz.get(campo) == null
            ? matriz.get(campoBruto)
            : matriz.get(campo);
          Object convertido;
          try {
            convertido = converter(raw, mdt == null ? 'TEXT' : mdt.Tipo_Conversao__c, f);
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
      List<SObject> stripped = d.getRecords();
      Database.SaveResult[] srs = Database.update(stripped, false);
      for (Integer i = 0; i < srs.size(); i++) {
        if (!srs[i].isSuccess()) {
          leadsComFalha.add(updIds[i]);
        }
      }
    }

    // Resultado por linha.
    for (SOL_Enriquecimento_Linha__c l : linhas) {
      List<String> erros = errosPorLinha.get(l.Id);
      Integer tocados = tocadosPorLinha.get(l.Id);
      Boolean houveFalhaDml = false;
      for (Id leadId : leadsDaLinha.get(l.Id)) {
        if (leadsComFalha.contains(leadId)) {
          houveFalhaDml = true;
          erros.add('Falha ao gravar o Lead ' + leadId + '.');
        }
      }
      if (houveFalhaDml && tocados == 0) {
        l.Resultado_Processamento__c = 'ERRO';
        acc.erros++;
      } else if (tocados > 0) {
        l.Resultado_Processamento__c = 'Atualizado: ' + tocados + ' Lead(s)';
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
    List<SOL_Enriquecimento_Linha__c> linhas,
    Map<String, SOL_Lemit_Mapeamento__mdt> matriz,
    Map<String, Schema.SObjectField> camposLead,
    Acumulador acc
  ) {
    if (linhas.isEmpty()) {
      return;
    }
    Id rt = rtSol();
    String statusInicial = statusFunilPadrao();

    List<Lead> novos = new List<Lead>();
    List<SOL_Enriquecimento_Linha__c> linhasCriar = new List<SOL_Enriquecimento_Linha__c>();
    List<List<String>> errosCriar = new List<List<String>>();

    for (SOL_Enriquecimento_Linha__c l : linhas) {
      Map<String, String> valores = payloadDe(l);
      String company = valores.get('Company');
      String lastName = valores.get('LastName');
      String norm = l.CNPJ_Normalizado__c;
      if (
        String.isBlank(company) ||
        String.isBlank(lastName) ||
        !SOLEnriquecimentoUtil.cnpjValido(norm)
      ) {
        l.Resultado_Processamento__c = 'ERRO';
        l.Erro__c = 'Sem Company/LastName ou CNPJ inválido — não criado.';
        acc.erros++;
        continue;
      }

      Lead nova = new Lead(
        RecordTypeId = rt,
        Unidade_Origem__c = 'SOL',
        Company = company.abbreviate(255),
        LastName = lastName.abbreviate(80),
        CNPJ__c = SOLEnriquecimentoUtil.formatarCnpj(norm),
        SOL_CNPJ_Normalizado__c = norm,
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
        SOL_Lemit_Mapeamento__mdt mdt = matriz.get(campo);
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

    // FLS de criação via stripInaccessible. O insert dispara SOL_Distribuir_Lead
    // (round-robin + Task "1ª Ligação") em contexto de sistema — não setamos
    // OwnerId nem status de distribuição aqui.
    SObjectAccessDecision d = Security.stripInaccessible(
      AccessType.CREATABLE,
      novos
    );
    List<SObject> stripped = d.getRecords();
    Database.SaveResult[] srs = Database.insert(stripped, false);
    for (Integer i = 0; i < srs.size(); i++) {
      SOL_Enriquecimento_Linha__c l = linhasCriar[i];
      List<String> erros = errosCriar[i];
      if (srs[i].isSuccess()) {
        l.Lead_Resultante__c = srs[i].getId();
        l.Resultado_Processamento__c = 'Criado';
        acc.criadas++;
      } else {
        l.Resultado_Processamento__c = 'ERRO';
        erros.add(mensagemErro(srs[i]));
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

  private static Map<Id, Lead> consultarLeads(
    Set<Id> ids,
    Set<String> campos
  ) {
    // Campos vêm do describe validado (não é input de usuário). Ids em bind.
    List<String> lista = new List<String>(campos);
    String q =
      'SELECT Id, ' +
      String.join(lista, ', ') +
      ' FROM Lead WHERE Id IN :ids';
    Map<Id, Lead> m = new Map<Id, Lead>();
    for (
      Lead l : (List<Lead>) Database.query(q, AccessLevel.USER_MODE)
    ) {
      m.put(l.Id, l);
    }
    return m;
  }

  private static Boolean campoAtualizavel(
    String campoBruto,
    Map<String, SOL_Lemit_Mapeamento__mdt> matriz,
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
    // Só aplica campos que estão na matriz CMDT (por API name).
    return matriz.containsKey(api) || matriz.containsKey(campoBruto);
  }

  private static List<Id> idsSelecionados(SOL_Enriquecimento_Linha__c l) {
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
    }
    return ids;
  }

  private static Map<String, String> payloadDe(SOL_Enriquecimento_Linha__c l) {
    if (String.isBlank(l.Payload_JSON__c)) {
      return new Map<String, String>();
    }
    try {
      Map<String, Object> cru = (Map<String, Object>) JSON.deserializeUntyped(
        l.Payload_JSON__c
      );
      Map<String, String> saida = new Map<String, String>();
      for (String k : cru.keySet()) {
        saida.put(k, cru.get(k) == null ? null : String.valueOf(cru.get(k)));
      }
      return saida;
    } catch (Exception e) {
      return new Map<String, String>();
    }
  }

  private static Boolean vazio(Object v) {
    return v == null || String.valueOf(v) == '';
  }

  /**
   * Converte o texto da célula para o tipo do campo de Lead, usando o
   * Tipo_Conversao__c como estratégia de parse e coagindo ao tipo Apex real do
   * campo (evita "Illegal assignment"). Lança em valor inválido.
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
      return v.equalsIgnoreCase('true') ||
        v == '1' ||
        v.equalsIgnoreCase('sim');
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

  private static String mensagemErro(Database.SaveResult sr) {
    List<String> ms = new List<String>();
    for (Database.Error e : sr.getErrors()) {
      ms.add(e.getStatusCode() + ': ' + e.getMessage());
    }
    return String.join(ms, '; ').abbreviate(2000);
  }
}
