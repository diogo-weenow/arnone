/**
 * Upload enriquecimento Lemit — orquestração do fluxo de enriquecimento de
 * Leads por CNPJ a partir de um arquivo Lemit.
 *
 * Consumido pelo LWC solEnriquecimentoLemit. O parse do CSV e o mapeamento das
 * colunas acontecem no cliente; aqui o servidor persiste o lote e as linhas,
 * classifica o casamento por CNPJ, aceita a confirmação do operador e enfileira
 * o SOLEnriquecimentoBatch. A gravação efetiva dos Leads é do batch.
 *
 * `with sharing`: respeita o compartilhamento em nível de registro do usuário
 * operador. Toda LEITURA de Lead é em USER_MODE (FLS/CRUD do operador). Os CNPJs
 * entram na consulta como BIND (`IN :cnpjs`), nunca concatenados — sem risco de
 * SOQL injection. As linhas chegam em chunks para não estourar heap/request.
 *
 * O match considera apenas Leads do Record Type SOL (DeveloperName 'SOL'): o
 * enriquecimento Lemit é do funil Arnone Soluções, cria Lead SOL quando não há
 * match e não deve tocar Leads de outras unidades. Lead convertido casa num
 * balde próprio e é ignorado.
 */
public with sharing class SOLEnriquecimentoController {
  @TestVisible
  private static final String SOL_RT = 'SOL';

  /** Teto por upload (decisão do P.O.). Guarda contra arquivos absurdos. */
  @TestVisible
  private static final Integer MAX_LINHAS = 5000;

  /** Chunk de gravação das linhas classificadas, para limitar heap. */
  private static final Integer CHUNK_UPDATE = 500;

  /** Amostra por balde devolvida ao preview (os MATCH_MULTIPLO vão inteiros). */
  private static final Integer AMOSTRA_POR_BALDE = 200;

  /** Teto de linhas MATCH_MULTIPLO devolvidas para seleção interativa. */
  private static final Integer MAX_MULTIPLO_RETORNO = 500;

  public class EnriquecimentoException extends Exception {
  }

  // ==================================================================
  //  DTOs
  // ==================================================================

  public class MapeamentoDTO {
    @AuraEnabled
    public String coluna;
    @AuraEnabled
    public String campoLead;
    @AuraEnabled
    public String label;
    @AuraEnabled
    public String politica;
    @AuraEnabled
    public Boolean usarNaCriacao;
    @AuraEnabled
    public String tipoConversao;
    @AuraEnabled
    public Decimal ordem;
  }

  public class ConfiguracaoDTO {
    @AuraEnabled
    public List<MapeamentoDTO> mapeamentos = new List<MapeamentoDTO>();
    @AuraEnabled
    public Integer maxLinhas;
  }

  public class LinhaDTO {
    @AuraEnabled
    public Integer numeroLinha;
    @AuraEnabled
    public String cnpj;
    // campoLeadApiName -> valor de texto bruto (inclui Company/LastName).
    @AuraEnabled
    public Map<String, String> valores;
  }

  public class LeadAlvoDTO {
    @AuraEnabled
    public Id id;
    @AuraEnabled
    public String nome;
    @AuraEnabled
    public String empresa;
    @AuraEnabled
    public String owner;
    @AuraEnabled
    public Boolean selecionado;
  }

  public class LinhaPreviewDTO {
    @AuraEnabled
    public Id linhaId;
    @AuraEnabled
    public Integer numeroLinha;
    @AuraEnabled
    public String cnpjOriginal;
    @AuraEnabled
    public String cnpjNormalizado;
    @AuraEnabled
    public String resultadoMatch;
    @AuraEnabled
    public String acao;
    @AuraEnabled
    public String resumo;
    @AuraEnabled
    public List<LeadAlvoDTO> leadsAlvo = new List<LeadAlvoDTO>();
  }

  public class PreviewDTO {
    @AuraEnabled
    public Id loteId;
    @AuraEnabled
    public String loteNome;
    @AuraEnabled
    public Integer total = 0;
    @AuraEnabled
    public Integer matchUnico = 0;
    @AuraEnabled
    public Integer matchMultiplo = 0;
    @AuraEnabled
    public Integer semMatch = 0;
    @AuraEnabled
    public Integer convertido = 0;
    @AuraEnabled
    public Integer invalido = 0;
    @AuraEnabled
    public Integer duplicado = 0;
    @AuraEnabled
    public List<LinhaPreviewDTO> multiplos = new List<LinhaPreviewDTO>();
    @AuraEnabled
    public List<LinhaPreviewDTO> amostra = new List<LinhaPreviewDTO>();
  }

  public class SelecaoDTO {
    @AuraEnabled
    public Id linhaId;
    @AuraEnabled
    public String acao;
    @AuraEnabled
    public List<Id> leadsSelecionados;
  }

  public class StatusDTO {
    @AuraEnabled
    public Id loteId;
    @AuraEnabled
    public String loteNome;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public String jobStatus;
    @AuraEnabled
    public Integer qtdLinhas = 0;
    @AuraEnabled
    public Integer qtdAtualizados = 0;
    @AuraEnabled
    public Integer qtdCriados = 0;
    @AuraEnabled
    public Integer qtdMultiplos = 0;
    @AuraEnabled
    public Integer qtdSemMatch = 0;
    @AuraEnabled
    public Integer qtdConvertidos = 0;
    @AuraEnabled
    public Integer qtdInvalidos = 0;
    @AuraEnabled
    public Integer qtdIgnorados = 0;
    @AuraEnabled
    public Integer qtdErros = 0;
    @AuraEnabled
    public String mensagens;
  }

  // ==================================================================
  //  Matriz CMDT
  // ==================================================================

  /**
   * Costura de teste: CMDT não aceita DML, então os testes injetam uma matriz
   * determinística em memória em vez de depender dos registros deployados.
   */
  @TestVisible
  private static Map<String, SOL_Lemit_Mapeamento__mdt> matrizOverride;

  /** Mapeamentos ativos por API name do campo de Lead. getAll() não gasta SOQL. */
  public static Map<String, SOL_Lemit_Mapeamento__mdt> matrizPorCampo() {
    if (matrizOverride != null) {
      return matrizOverride;
    }
    Map<String, SOL_Lemit_Mapeamento__mdt> porCampo = new Map<String, SOL_Lemit_Mapeamento__mdt>();
    for (SOL_Lemit_Mapeamento__mdt m : SOL_Lemit_Mapeamento__mdt.getAll().values()) {
      if (m.Ativo__c == true && String.isNotBlank(m.Campo_Lead__c)) {
        porCampo.put(m.Campo_Lead__c, m);
      }
    }
    return porCampo;
  }

  @AuraEnabled(cacheable=true)
  public static ConfiguracaoDTO getConfiguracao() {
    try {
      ConfiguracaoDTO cfg = new ConfiguracaoDTO();
      cfg.maxLinhas = MAX_LINHAS;

      Map<String, Schema.SObjectField> campos = Schema.SObjectType.Lead.fields.getMap();
      List<SOL_Lemit_Mapeamento__mdt> ordenados = new List<SOL_Lemit_Mapeamento__mdt>(
        SOL_Lemit_Mapeamento__mdt.getAll().values()
      );
      // Ordena por Ordem__c asc (nulos ao fim) — função pura em memória.
      ordenados.sort(new PorOrdem());

      for (SOL_Lemit_Mapeamento__mdt m : ordenados) {
        if (m.Ativo__c != true || String.isBlank(m.Campo_Lead__c)) {
          continue;
        }
        MapeamentoDTO dto = new MapeamentoDTO();
        dto.coluna = m.Coluna_Lemit__c;
        dto.campoLead = m.Campo_Lead__c;
        dto.politica = m.Politica__c;
        dto.usarNaCriacao = m.Usar_Na_Criacao__c;
        dto.tipoConversao = m.Tipo_Conversao__c;
        dto.ordem = m.Ordem__c;
        Schema.SObjectField f = campos.get(m.Campo_Lead__c.toLowerCase());
        dto.label = f == null
          ? m.Campo_Lead__c
          : f.getDescribe().getLabel();
        cfg.mapeamentos.add(dto);
      }
      return cfg;
    } catch (Exception e) {
      throw aura(e);
    }
  }

  private class PorOrdem implements Comparator<SOL_Lemit_Mapeamento__mdt> {
    public Integer compare(
      SOL_Lemit_Mapeamento__mdt a,
      SOL_Lemit_Mapeamento__mdt b
    ) {
      Decimal oa = a.Ordem__c == null ? 999999 : a.Ordem__c;
      Decimal ob = b.Ordem__c == null ? 999999 : b.Ordem__c;
      if (oa == ob) {
        return 0;
      }
      return oa < ob ? -1 : 1;
    }
  }

  // ==================================================================
  //  (a) Iniciar lote + carregar linhas em chunks
  // ==================================================================

  @AuraEnabled
  public static Id iniciarLote(String nomeArquivo, Integer totalLinhas) {
    try {
      if (totalLinhas == null || totalLinhas <= 0) {
        throw new EnriquecimentoException('O arquivo não tem linhas de dados.');
      }
      if (totalLinhas > MAX_LINHAS) {
        throw new EnriquecimentoException(
          'O arquivo tem ' +
            totalLinhas +
            ' linhas; o máximo por upload é ' +
            MAX_LINHAS +
            '.'
        );
      }
      SOL_Enriquecimento_Lote__c lote = new SOL_Enriquecimento_Lote__c(
        Status__c = 'Em preview',
        Qtd_Linhas__c = totalLinhas,
        Mensagens__c = String.isBlank(nomeArquivo)
          ? null
          : 'Arquivo: ' + nomeArquivo.abbreviate(900)
      );
      insert lote;
      return lote.Id;
    } catch (Exception e) {
      throw aura(e);
    }
  }

  @AuraEnabled
  public static void adicionarLinhas(Id loteId, String linhasJson) {
    try {
      if (loteId == null || String.isBlank(linhasJson)) {
        return;
      }
      // A LWC envia as linhas como string JSON e desserializamos aqui: um campo
      // Map<String,String> dentro de um tipo Apex NÃO é preenchido pela
      // marshalling nativa LWC->Apex (zera o objeto inteiro). JSON.deserialize
      // preenche corretamente.
      List<LinhaDTO> linhas = (List<LinhaDTO>) JSON.deserialize(
        linhasJson,
        List<LinhaDTO>.class
      );
      if (linhas == null || linhas.isEmpty()) {
        return;
      }
      List<SOL_Enriquecimento_Linha__c> registros = new List<SOL_Enriquecimento_Linha__c>();
      for (LinhaDTO d : linhas) {
        String original = d.cnpj == null ? '' : d.cnpj;
        String normalizado = SOLEnriquecimentoUtil.normalizarCnpj(original);
        registros.add(
          new SOL_Enriquecimento_Linha__c(
            Lote__c = loteId,
            Numero_Linha__c = d.numeroLinha,
            CNPJ_Original__c = original.abbreviate(30),
            CNPJ_Normalizado__c = normalizado.length() > 14
              ? normalizado.substring(0, 14)
              : normalizado,
            Payload_JSON__c = JSON.serialize(
              d.valores == null ? new Map<String, String>() : d.valores
            )
          )
        );
      }
      insert registros;
    } catch (Exception e) {
      throw aura(e);
    }
  }

  // ==================================================================
  //  (b) Classificar o casamento por CNPJ
  // ==================================================================

  @AuraEnabled
  public static PreviewDTO classificar(Id loteId) {
    try {
      PreviewDTO preview = new PreviewDTO();
      preview.loteId = loteId;

      SOL_Enriquecimento_Lote__c lote = [
        SELECT Id, Name
        FROM SOL_Enriquecimento_Lote__c
        WHERE Id = :loteId
        LIMIT 1
      ];
      preview.loteNome = lote.Name;

      // Pass 1: coletar os CNPJs válidos (14 dígitos). Sem payload — leve.
      Set<String> cnpjs = new Set<String>();
      for (SOL_Enriquecimento_Linha__c l : [
        SELECT Id, CNPJ_Normalizado__c
        FROM SOL_Enriquecimento_Linha__c
        WHERE Lote__c = :loteId
      ]) {
        if (SOLEnriquecimentoUtil.cnpjValido(l.CNPJ_Normalizado__c)) {
          cnpjs.add(l.CNPJ_Normalizado__c);
        }
      }

      // Leads SOL que casam. CNPJs são BIND, nunca concatenados.
      Map<String, List<Lead>> ativosPorCnpj = new Map<String, List<Lead>>();
      Set<String> comConvertido = new Set<String>();
      // Bind LOCAL: WITH USER_MODE não aceita bind para constante estática
      // (lança "Variable does not exist: tmpVar1").
      String rtDev = SOL_RT;
      if (!cnpjs.isEmpty()) {
        // Leitura de MATCH em contexto de sistema (a classe `with sharing` ainda
        // impõe acesso em nível de registro). A FLS de Lead é imposta na
        // GRAVAÇÃO, pelo stripInaccessible do batch. O preview só devolve
        // Name/Company/Owner (campos padrão visíveis); CNPJ normalizado é usado
        // apenas para o casamento. CNPJs sempre em BIND, nunca concatenados.
        List<Lead> casadosLeads = [
          SELECT
            Id,
            Name,
            Company,
            IsConverted,
            Owner.Name,
            SOL_CNPJ_Normalizado__c
          FROM Lead
          WHERE
            SOL_CNPJ_Normalizado__c IN :cnpjs
            AND RecordType.DeveloperName = :rtDev
        ];
        for (Lead ld : casadosLeads) {
          String chave = ld.SOL_CNPJ_Normalizado__c;
          if (ld.IsConverted) {
            comConvertido.add(chave);
            continue;
          }
          if (!ativosPorCnpj.containsKey(chave)) {
            ativosPorCnpj.put(chave, new List<Lead>());
          }
          ativosPorCnpj.get(chave).add(ld);
        }
      }

      // Pass 2: classifica cada linha e grava. SOQL for-loop + updates em chunk.
      Set<String> semMatchVistos = new Set<String>();
      List<SOL_Enriquecimento_Linha__c> buffer = new List<SOL_Enriquecimento_Linha__c>();
      Integer multiplosDevolvidos = 0;
      Map<String, Integer> amostraPorBalde = new Map<String, Integer>();

      for (SOL_Enriquecimento_Linha__c l : [
        SELECT
          Id,
          Numero_Linha__c,
          CNPJ_Original__c,
          CNPJ_Normalizado__c,
          Payload_JSON__c
        FROM SOL_Enriquecimento_Linha__c
        WHERE Lote__c = :loteId
        ORDER BY Numero_Linha__c ASC NULLS LAST, Name ASC
      ]) {
        preview.total++;
        String norm = l.CNPJ_Normalizado__c;
        String balde;
        String acao;
        String resumo = '';
        List<LeadAlvoDTO> alvos = new List<LeadAlvoDTO>();

        if (!SOLEnriquecimentoUtil.cnpjValido(norm)) {
          balde = 'INVALIDO';
          acao = 'IGNORAR';
          resumo = 'CNPJ sem 14 dígitos.';
          preview.invalido++;
        } else if (
          ativosPorCnpj.containsKey(norm) &&
          !ativosPorCnpj.get(norm).isEmpty()
        ) {
          List<Lead> casados = ativosPorCnpj.get(norm);
          for (Lead c : casados) {
            LeadAlvoDTO a = new LeadAlvoDTO();
            a.id = c.Id;
            a.nome = c.Name;
            a.empresa = c.Company;
            a.owner = c.Owner == null ? null : c.Owner.Name;
            a.selecionado = true;
            alvos.add(a);
          }
          if (casados.size() == 1) {
            balde = 'MATCH_UNICO';
            acao = 'ATUALIZAR';
            preview.matchUnico++;
          } else {
            balde = 'MATCH_MULTIPLO';
            acao = 'ATUALIZAR';
            resumo = casados.size() + ' Leads casam este CNPJ.';
            preview.matchMultiplo++;
          }
        } else if (comConvertido.contains(norm)) {
          balde = 'CONVERTIDO';
          acao = 'IGNORAR';
          resumo = 'Só casou com Lead convertido.';
          preview.convertido++;
        } else {
          // Sem Lead SOL ativo nem convertido para este CNPJ.
          if (semMatchVistos.contains(norm)) {
            balde = 'DUPLICADO_NO_ARQUIVO';
            acao = 'IGNORAR';
            resumo = 'CNPJ repetido no arquivo sem match — não recria.';
            preview.duplicado++;
          } else {
            Map<String, String> valores = payloadDe(l);
            if (temCompanyELastName(valores)) {
              balde = 'SEM_MATCH';
              acao = 'CRIAR';
              semMatchVistos.add(norm);
              preview.semMatch++;
            } else {
              balde = 'INVALIDO';
              acao = 'IGNORAR';
              resumo = 'Sem Company e LastName mapeáveis — não dá pra criar.';
              preview.invalido++;
              // Não entra em semMatchVistos: outra linha do mesmo CNPJ com
              // Company/LastName ainda pode criar.
            }
          }
        }

        l.Resultado_Match__c = balde;
        l.Acao__c = acao;
        l.Leads_Alvo__c = alvos.isEmpty() ? null : JSON.serialize(alvos);
        l.Resultado_Processamento__c = null;
        l.Erro__c = resumo == '' ? null : resumo;
        buffer.add(l);

        // Monta o retorno para o preview (limitado).
        LinhaPreviewDTO p = new LinhaPreviewDTO();
        p.linhaId = l.Id;
        p.numeroLinha = l.Numero_Linha__c == null
          ? null
          : l.Numero_Linha__c.intValue();
        p.cnpjOriginal = l.CNPJ_Original__c;
        p.cnpjNormalizado = norm;
        p.resultadoMatch = balde;
        p.acao = acao;
        p.resumo = resumo;
        p.leadsAlvo = alvos;
        if (
          balde == 'MATCH_MULTIPLO' && multiplosDevolvidos < MAX_MULTIPLO_RETORNO
        ) {
          preview.multiplos.add(p);
          multiplosDevolvidos++;
        } else {
          Integer vistos = amostraPorBalde.containsKey(balde)
            ? amostraPorBalde.get(balde)
            : 0;
          if (vistos < AMOSTRA_POR_BALDE) {
            preview.amostra.add(p);
            amostraPorBalde.put(balde, vistos + 1);
          }
        }

        if (buffer.size() >= CHUNK_UPDATE) {
          update buffer;
          buffer.clear();
        }
      }
      if (!buffer.isEmpty()) {
        update buffer;
      }

      // Atualiza as contagens do lote (infra interna — contexto de sistema).
      lote.Qtd_Linhas__c = preview.total;
      lote.Qtd_Multiplos__c = preview.matchMultiplo;
      lote.Qtd_Sem_Match__c = preview.semMatch;
      lote.Qtd_Convertidos__c = preview.convertido;
      lote.Qtd_Invalidos__c = preview.invalido;
      update lote;

      return preview;
    } catch (Exception e) {
      throw aura(e);
    }
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

  private static Boolean temCompanyELastName(Map<String, String> valores) {
    return valores != null &&
      String.isNotBlank(valores.get('Company')) &&
      String.isNotBlank(valores.get('LastName'));
  }

  // ==================================================================
  //  (c) Confirmar e enfileirar o batch
  // ==================================================================

  @AuraEnabled
  public static Id confirmar(Id loteId, List<SelecaoDTO> selecoes) {
    try {
      if (loteId == null) {
        throw new EnriquecimentoException('Lote não informado.');
      }
      // Aplica os overrides do operador (seleção de múltiplos e ignorados).
      if (selecoes != null && !selecoes.isEmpty()) {
        Map<Id, SelecaoDTO> porLinha = new Map<Id, SelecaoDTO>();
        for (SelecaoDTO s : selecoes) {
          if (s != null && s.linhaId != null) {
            porLinha.put(s.linhaId, s);
          }
        }
        List<SOL_Enriquecimento_Linha__c> paraAtualizar = new List<SOL_Enriquecimento_Linha__c>();
        for (SOL_Enriquecimento_Linha__c l : [
          SELECT Id, Resultado_Match__c, Acao__c, Leads_Alvo__c
          FROM SOL_Enriquecimento_Linha__c
          WHERE Id IN :porLinha.keySet() AND Lote__c = :loteId
        ]) {
          SelecaoDTO s = porLinha.get(l.Id);
          if (String.isNotBlank(s.acao)) {
            l.Acao__c = s.acao;
          }
          // Reconstrói Leads_Alvo marcando selecionado só para os escolhidos.
          if (s.leadsSelecionados != null && String.isNotBlank(l.Leads_Alvo__c)) {
            Set<Id> escolhidos = new Set<Id>(s.leadsSelecionados);
            List<LeadAlvoDTO> alvos = (List<LeadAlvoDTO>) JSON.deserialize(
              l.Leads_Alvo__c,
              List<LeadAlvoDTO>.class
            );
            Boolean algum = false;
            for (LeadAlvoDTO a : alvos) {
              a.selecionado = escolhidos.contains(a.id);
              algum = algum || a.selecionado;
            }
            l.Leads_Alvo__c = JSON.serialize(alvos);
            // Múltiplo sem nenhum selecionado vira IGNORAR.
            if (!algum && l.Acao__c == 'ATUALIZAR') {
              l.Acao__c = 'IGNORAR';
            }
          }
          paraAtualizar.add(l);
        }
        if (!paraAtualizar.isEmpty()) {
          update paraAtualizar;
        }
      }

      SOL_Enriquecimento_Lote__c lote = [
        SELECT Id, Status__c
        FROM SOL_Enriquecimento_Lote__c
        WHERE Id = :loteId
        LIMIT 1
      ];
      lote.Status__c = 'Processando';
      update lote;

      Id jobId = Database.executeBatch(new SOLEnriquecimentoBatch(loteId), 50);

      lote.AsyncApexJobId__c = String.valueOf(jobId);
      update lote;
      return jobId;
    } catch (Exception e) {
      throw aura(e);
    }
  }

  // ==================================================================
  //  (d) Consultar status (polling)
  // ==================================================================

  @AuraEnabled
  public static StatusDTO consultarStatus(Id loteId) {
    try {
      SOL_Enriquecimento_Lote__c lote = [
        SELECT
          Id,
          Name,
          Status__c,
          AsyncApexJobId__c,
          Qtd_Linhas__c,
          Qtd_Atualizados__c,
          Qtd_Criados__c,
          Qtd_Multiplos__c,
          Qtd_Sem_Match__c,
          Qtd_Convertidos__c,
          Qtd_Invalidos__c,
          Qtd_Ignorados__c,
          Qtd_Erros__c,
          Mensagens__c
        FROM SOL_Enriquecimento_Lote__c
        WHERE Id = :loteId
        LIMIT 1
      ];

      StatusDTO dto = new StatusDTO();
      dto.loteId = lote.Id;
      dto.loteNome = lote.Name;
      dto.status = lote.Status__c;
      dto.qtdLinhas = inteiro(lote.Qtd_Linhas__c);
      dto.qtdAtualizados = inteiro(lote.Qtd_Atualizados__c);
      dto.qtdCriados = inteiro(lote.Qtd_Criados__c);
      dto.qtdMultiplos = inteiro(lote.Qtd_Multiplos__c);
      dto.qtdSemMatch = inteiro(lote.Qtd_Sem_Match__c);
      dto.qtdConvertidos = inteiro(lote.Qtd_Convertidos__c);
      dto.qtdInvalidos = inteiro(lote.Qtd_Invalidos__c);
      dto.qtdIgnorados = inteiro(lote.Qtd_Ignorados__c);
      dto.qtdErros = inteiro(lote.Qtd_Erros__c);
      dto.mensagens = lote.Mensagens__c;

      if (String.isNotBlank(lote.AsyncApexJobId__c)) {
        List<AsyncApexJob> jobs = [
          SELECT Status, NumberOfErrors, ExtendedStatus
          FROM AsyncApexJob
          WHERE Id = :lote.AsyncApexJobId__c
          LIMIT 1
        ];
        if (!jobs.isEmpty()) {
          dto.jobStatus = jobs[0].Status;
        }
      }
      return dto;
    } catch (Exception e) {
      throw aura(e);
    }
  }

  private static Integer inteiro(Decimal d) {
    return d == null ? 0 : d.intValue();
  }

  /** Converte qualquer exceção em mensagem controlada para o LWC. */
  private static AuraHandledException aura(Exception e) {
    System.debug(
      LoggingLevel.ERROR,
      'SOLEnriquecimentoController: ' +
        e.getTypeName() +
        ': ' +
        e.getMessage() +
        '\n' +
        e.getStackTraceString()
    );
    String msg = e instanceof EnriquecimentoException
      ? e.getMessage()
      : 'Não foi possível concluir a operação. Verifique o log do sistema para detalhes.';
    AuraHandledException ex = new AuraHandledException(msg);
    ex.setMessage(msg);
    return ex;
  }
}
