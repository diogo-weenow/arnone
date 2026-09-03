/**
 * CLICKUP-9420 — Card 09 — Registro da solicitação (externa) do cálculo ao
 * jurídico.
 *
 * Aplica-se SOMENTE a Oportunidades: Record Type SOL, produto "Recuperação
 * Tributária", etapa "Diagnóstico", abertas, originadas da conversão de um Lead
 * SOL. ART 360 fica fora (o funil dele vai direto para "Negociação").
 *
 * Grava Opportunity.SOL_Data_Solicitacao_Calculo__c — que será a ORIGEM do
 * prazo do CLICKUP-9421. Este card NÃO calcula vencimento nem cria tarefa.
 *
 * Antes de gravar, confirma: Opp SOL + Recuperação Tributária + aberta + em
 * "Diagnóstico"; Lead convertido vinculado por ConvertedOpportunityId; no Lead:
 * SOL_Data_Reuniao_Realizada__c preenchida, procuração "Recebida", data de
 * recebimento preenchida; documento (ContentDocumentLink) no Lead OU na
 * Oportunidade. Qualquer falha => mensagem controlada, sem gravar.
 *
 * Solicitação ÚNICA: se a data já estiver preenchida, não sobrescreve e informa
 * que já foi registrada. Concorrência: SELECT ... FOR UPDATE na Oportunidade.
 *
 * Bulk-safe: nenhuma consulta/DML em laço. Acesso ao registro respeitado
 * (with sharing). Falha atômica: Savepoint + rollback + SolicitacaoCalculoException.
 */
public with sharing class SOLSolicitarCalculoService {
  @TestVisible
  private static final String RT_OPP = 'SOL';
  @TestVisible
  private static final String PRODUTO_RECUPERACAO = 'Recuperação Tributária';
  @TestVisible
  private static final String ETAPA_DIAGNOSTICO = 'Diagnóstico';
  @TestVisible
  private static final String PROC_RECEBIDA = 'Recebida';

  /** Mensagem controlada quando a gravação falha por erro técnico. */
  public static final String MSG_FALHA = 'Não foi possível registrar a solicitação do cálculo. Nenhuma alteração foi salva — tente novamente.';

  /** Falha técnica controlada (a transação deve ser abortada). */
  public class SolicitacaoCalculoException extends Exception {
  }

  /** Pedido: uma Oportunidade + a data informada pelo vendedor. */
  public class Pedido {
    public Id opportunityId;
    public Date dataSolicitacao;

    public Pedido() {
    }
    public Pedido(Id opportunityId, Date dataSolicitacao) {
      this.opportunityId = opportunityId;
      this.dataSolicitacao = dataSolicitacao;
    }
  }

  /** Resultado controlado por pedido. */
  public class Resultado {
    public Id opportunityId;
    public Boolean sucesso = false;
    public Boolean jaRegistrado = false;
    public String mensagem;
  }

  /**
   * Registra a data da solicitação do cálculo para os pedidos informados.
   *
   * @return um Resultado por pedido (mesma ordem).
   * @throws SolicitacaoCalculoException falha técnica na gravação.
   */
  public static List<Resultado> registrar(List<Pedido> pedidos) {
    List<Resultado> saidas = new List<Resultado>();
    if (pedidos == null || pedidos.isEmpty()) {
      return saidas;
    }

    Set<Id> oppIds = new Set<Id>();
    for (Pedido p : pedidos) {
      if (p != null && p.opportunityId != null) {
        oppIds.add(p.opportunityId);
      }
    }

    Savepoint sp = null;
    try {
      sp = Database.setSavepoint();

      // Trava as Oportunidades: serializa gravações concorrentes do mesmo registro.
      Map<Id, Opportunity> opps = new Map<Id, Opportunity>(
        [
          SELECT
            Id,
            StageName,
            IsClosed,
            SOL_Produto_Negocio__c,
            SOL_Data_Solicitacao_Calculo__c,
            RecordType.DeveloperName
          FROM Opportunity
          WHERE Id IN :oppIds
          FOR UPDATE
        ]
      );

      // Oportunidades elegíveis pelos critérios da própria Opp.
      Set<Id> elegiveis = new Set<Id>();
      for (Id oid : oppIds) {
        Opportunity o = opps.get(oid);
        if (
          o != null &&
          o.RecordType.DeveloperName == RT_OPP &&
          o.SOL_Produto_Negocio__c == PRODUTO_RECUPERACAO &&
          o.IsClosed == false &&
          o.StageName == ETAPA_DIAGNOSTICO
        ) {
          elegiveis.add(oid);
        }
      }

      // Lead convertido vinculado a cada Oportunidade elegível.
      Map<Id, Lead> leadPorOpp = new Map<Id, Lead>();
      if (!elegiveis.isEmpty()) {
        for (Lead l : [
          SELECT
            ConvertedOpportunityId,
            SOL_Data_Reuniao_Realizada__c,
            SOL_Status_Procuracao__c,
            SOL_Data_Recebimento_Procuracao__c
          FROM Lead
          WHERE ConvertedOpportunityId IN :elegiveis AND IsConverted = TRUE
        ]) {
          leadPorOpp.put(l.ConvertedOpportunityId, l);
        }
      }

      // Documento no Lead OU na Oportunidade.
      Set<Id> comDocumento = new Set<Id>();
      Set<Id> alvosDoc = new Set<Id>(elegiveis);
      for (Lead l : leadPorOpp.values()) {
        alvosDoc.add(l.Id);
      }
      if (!alvosDoc.isEmpty()) {
        for (ContentDocumentLink cdl : [
          SELECT LinkedEntityId
          FROM ContentDocumentLink
          WHERE LinkedEntityId IN :alvosDoc
        ]) {
          comDocumento.add(cdl.LinkedEntityId);
        }
      }

      List<Opportunity> paraAtualizar = new List<Opportunity>();
      for (Pedido p : pedidos) {
        Resultado r = new Resultado();
        r.opportunityId = p == null ? null : p.opportunityId;
        saidas.add(r);

        if (p == null || p.opportunityId == null) {
          r.mensagem = 'Oportunidade não informada.';
          continue;
        }
        Opportunity o = opps.get(p.opportunityId);
        if (o == null) {
          r.mensagem = 'Oportunidade não encontrada ou sem acesso.';
          continue;
        }
        if (o.RecordType.DeveloperName != RT_OPP) {
          r.mensagem = 'Esta Oportunidade não é da Arnone Soluções.';
          continue;
        }
        if (o.SOL_Produto_Negocio__c != PRODUTO_RECUPERACAO) {
          r.mensagem = 'O cálculo jurídico só existe em Recuperação Tributária. ART 360 vai direto para a Negociação.';
          continue;
        }
        if (o.IsClosed) {
          r.mensagem = 'Esta Oportunidade está fechada.';
          continue;
        }
        if (o.StageName != ETAPA_DIAGNOSTICO) {
          r.mensagem = 'A solicitação do cálculo só é registrada na etapa Diagnóstico.';
          continue;
        }
        if (o.SOL_Data_Solicitacao_Calculo__c != null) {
          r.jaRegistrado = true;
          r.mensagem =
            'A solicitação do cálculo já foi registrada em ' +
            o.SOL_Data_Solicitacao_Calculo__c.format() +
            '.';
          continue;
        }
        if (p.dataSolicitacao == null) {
          r.mensagem = 'Informe a data em que o cálculo foi solicitado ao jurídico.';
          continue;
        }
        if (p.dataSolicitacao > Date.today()) {
          r.mensagem = 'A data da solicitação não pode ser futura. Use a data de hoje ou uma data passada.';
          continue;
        }

        Lead l = leadPorOpp.get(p.opportunityId);
        if (l == null) {
          r.mensagem = 'Não foi encontrado o Lead convertido desta Oportunidade.';
          continue;
        }
        if (l.SOL_Data_Reuniao_Realizada__c == null) {
          r.mensagem = 'A reunião comercial ainda não foi realizada.';
          continue;
        }
        if (l.SOL_Status_Procuracao__c != PROC_RECEBIDA) {
          r.mensagem = 'A procuração ainda não foi recebida.';
          continue;
        }
        if (l.SOL_Data_Recebimento_Procuracao__c == null) {
          r.mensagem = 'A data do recebimento da procuração não está preenchida.';
          continue;
        }
        if (!comDocumento.contains(p.opportunityId) && !comDocumento.contains(l.Id)) {
          r.mensagem = 'O documento da procuração não está anexado ao Lead nem à Oportunidade.';
          continue;
        }

        paraAtualizar.add(
          new Opportunity(
            Id = p.opportunityId,
            SOL_Data_Solicitacao_Calculo__c = p.dataSolicitacao
          )
        );
        r.sucesso = true;
        r.mensagem = 'Solicitação do cálculo registrada em ' + p.dataSolicitacao.format() + '.';
      }

      if (!paraAtualizar.isEmpty()) {
        update paraAtualizar;
      }
      return saidas;
    } catch (SolicitacaoCalculoException e) {
      if (sp != null) {
        Database.rollback(sp);
      }
      throw e;
    } catch (Exception e) {
      if (sp != null) {
        Database.rollback(sp);
      }
      System.debug(
        LoggingLevel.ERROR,
        'SOLSolicitarCalculoService: ' +
          e.getTypeName() +
          ': ' +
          e.getMessage() +
          '\n' +
          e.getStackTraceString()
      );
      throw new SolicitacaoCalculoException(MSG_FALHA);
    }
  }
}
