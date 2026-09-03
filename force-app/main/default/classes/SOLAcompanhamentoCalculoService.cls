/**
 * CLICKUP-9421 — Card 10 — Criação automática da tarefa de acompanhamento do
 * cálculo jurídico.
 *
 * Quando uma Oportunidade da Arnone Soluções tem SOL_Data_Solicitacao_Calculo__c
 * preenchida pela primeira vez (ação guiada do CLICKUP-9420), e a Opp está no
 * escopo — Record Type SOL, produto "Recuperação Tributária", etapa "Diagnóstico",
 * aberta — cria UMA Task "Acompanhar recebimento do cálculo jurídico" para o
 * proprietário atual da Oportunidade, com vencimento 7 dias ÚTEIS depois da data
 * da solicitação. ART 360 fica fora (o funil dele vai direto para "Negociação").
 *
 * Serviço dedicado. Bulk-safe: nenhuma consulta/DML em laço. Concorrência:
 * Oportunidade travada com FOR UPDATE. Dias úteis / feriados / timezone de São
 * Paulo: SOLBusinessHoursHelper (mesma lógica do CLICKUP-9401/9426 — sem copiar
 * o algoritmo, sem 7 dias corridos, sem grade fixa seg–sex, sem fallback
 * silencioso).
 *
 * IDENTIDADE DA SOLICITAÇÃO: a Task guarda SOL_Data_Solicitacao_Calculo_Ref__c =
 * a data registrada na Oportunidade. Idempotência pela chave (Opportunity + data
 * da solicitação), consultando tarefas de QUALQUER status:
 *  - reprocessamento / atualização não relacionada não duplica (mesmo com a
 *    tarefa anterior aberta ou encerrada);
 *  - no máximo uma tarefa por Oportunidade e por solicitação.
 *
 * ATÔMICO: em qualquer falha (inclusive calendário ausente), o Savepoint desfaz
 * o trabalho feito DENTRO deste serviço após a sua criação e o método RELANÇA
 * {@link AcompanhamentoCalculoException}. O registro da data no Card 09 (o
 * update que disparou o Flow) é desfeito porque a exceção é propagada pelo
 * Invocable ao Flow (flowTransactionModel = CurrentTransaction), abortando a
 * transação completa. Resultado: sem estado parcial — a data da solicitação
 * também é revertida.
 *
 * NÃO avança a Oportunidade nem cria a reunião final (isso é o CLICKUP-9422).
 * NÃO trata o recebimento do cálculo (campo Task.SOL_Data_Recebimento_Calculo__c
 * + VRs).
 */
public without sharing class SOLAcompanhamentoCalculoService {
  @TestVisible
  private static final String RECORD_TYPE_SOL = 'SOL';
  @TestVisible
  private static final String PRODUTO_RECUPERACAO = 'Recuperação Tributária';
  @TestVisible
  private static final String ETAPA_DIAGNOSTICO = 'Diagnóstico';
  @TestVisible
  private static final String SUBJECT_ACOMPANHAMENTO = 'Acompanhar recebimento do cálculo jurídico';
  @TestVisible
  private static final String TIPO_TAREFA_ACOMPANHAMENTO = 'Acompanhamento do cálculo jurídico';
  @TestVisible
  private static final String TASK_STATUS_ABERTO = 'Open';
  @TestVisible
  private static final Integer DIAS_UTEIS_PRAZO = 7;

  /** Mensagem controlada exibida ao vendedor quando a criação da tarefa falha. */
  public static final String MSG_FALHA = 'Não foi possível criar a tarefa de acompanhamento do cálculo jurídico. Nenhuma alteração foi salva — registre a solicitação novamente.';
  /** Mensagem controlada quando o calendário comercial não está configurado. */
  public static final String MSG_SEM_CALENDARIO = 'A tarefa de acompanhamento do cálculo jurídico não foi criada: o calendário "Arnone Soluções - Horário Comercial" não está ativo. Nenhuma alteração foi salva.';

  /** Falha controlada da criação da tarefa de acompanhamento (CLICKUP-9421). */
  public class AcompanhamentoCalculoException extends Exception {
  }

  /** Resultado controlado da criação da tarefa de acompanhamento do cálculo. */
  public class ResultadoAcompanhamento {
    /** Tarefas de acompanhamento criadas agora. */
    public Integer tarefasCriadas = 0;
    /** Oportunidades fora do escopo, sem solicitação registrada, ou que já tinham a tarefa desta solicitação. */
    public Integer ignorados = 0;
  }

  /**
   * Cria a Task "Acompanhar recebimento do cálculo jurídico" para as
   * Oportunidades que acabaram de registrar a solicitação do cálculo.
   *
   * @param opportunityIds Ids de Opportunity (qualquer origem; filtrados aqui).
   * @return contagens controladas.
   * @throws AcompanhamentoCalculoException falha ao criar / calendário ausente
   *   (a transação deve ser abortada).
   */
  public static ResultadoAcompanhamento criarTarefaAcompanhamento(List<Id> opportunityIds) {
    ResultadoAcompanhamento r = new ResultadoAcompanhamento();
    if (opportunityIds == null || opportunityIds.isEmpty()) {
      return r;
    }

    Set<Id> ids = new Set<Id>();
    for (Id oid : opportunityIds) {
      if (oid != null && oid.getSObjectType() == Opportunity.SObjectType) {
        ids.add(oid);
      }
    }
    if (ids.isEmpty()) {
      return r;
    }

    Savepoint sp = null;
    try {
      sp = Database.setSavepoint();

      // Trava as Oportunidades: serializa execuções concorrentes da mesma Opp.
      List<Opportunity> carregadas = [
        SELECT
          Id,
          OwnerId,
          StageName,
          IsClosed,
          SOL_Produto_Negocio__c,
          SOL_Data_Solicitacao_Calculo__c,
          RecordType.DeveloperName
        FROM Opportunity
        WHERE Id IN :ids
        FOR UPDATE
      ];

      Map<Id, Id> donoPorOpp = new Map<Id, Id>();
      Map<Id, Date> solicitacaoPorOpp = new Map<Id, Date>();
      Set<Id> encontradas = new Set<Id>();
      for (Opportunity o : carregadas) {
        encontradas.add(o.Id);
        Boolean elegivel =
          o.RecordType.DeveloperName == RECORD_TYPE_SOL &&
          o.SOL_Produto_Negocio__c == PRODUTO_RECUPERACAO &&
          o.IsClosed == false &&
          o.StageName == ETAPA_DIAGNOSTICO &&
          o.SOL_Data_Solicitacao_Calculo__c != null;
        if (elegivel) {
          donoPorOpp.put(o.Id, o.OwnerId);
          solicitacaoPorOpp.put(o.Id, o.SOL_Data_Solicitacao_Calculo__c);
        } else {
          r.ignorados++;
        }
      }
      r.ignorados += (ids.size() - encontradas.size());

      if (donoPorOpp.isEmpty()) {
        return r;
      }

      // Idempotência pela chave (Opportunity + data da solicitação), QUALQUER status.
      Set<String> jaExiste = new Set<String>();
      for (Task t : [
        SELECT WhatId, SOL_Data_Solicitacao_Calculo_Ref__c
        FROM Task
        WHERE
          WhatId IN :donoPorOpp.keySet()
          AND SOL_Tipo_Tarefa__c = :TIPO_TAREFA_ACOMPANHAMENTO
          AND SOL_Data_Solicitacao_Calculo_Ref__c != null
      ]) {
        jaExiste.add(chave(t.WhatId, t.SOL_Data_Solicitacao_Calculo_Ref__c));
      }
      for (Id oppId : new Set<Id>(donoPorOpp.keySet())) {
        if (jaExiste.contains(chave(oppId, solicitacaoPorOpp.get(oppId)))) {
          donoPorOpp.remove(oppId);
          r.ignorados++;
        }
      }

      if (donoPorOpp.isEmpty()) {
        return r;
      }

      Id bhId = SOLBusinessHoursHelper.businessHoursId();
      if (bhId == null) {
        throw new AcompanhamentoCalculoException(MSG_SEM_CALENDARIO);
      }

      // Prazo por data de solicitação — resolvido uma vez por data distinta.
      Map<Date, Date> vencimentoPorSolicitacao = new Map<Date, Date>();
      for (Id oppId : donoPorOpp.keySet()) {
        Date dataSolic = solicitacaoPorOpp.get(oppId);
        if (!vencimentoPorSolicitacao.containsKey(dataSolic)) {
          Datetime prazo = SOLBusinessHoursHelper.prazoEmDiasUteis(
            bhId,
            dataSolic,
            DIAS_UTEIS_PRAZO
          );
          vencimentoPorSolicitacao.put(
            dataSolic,
            SOLBusinessHoursHelper.dataEm(prazo, SOLBusinessHoursHelper.TZ_SAO_PAULO)
          );
        }
      }

      List<Task> novas = new List<Task>();
      for (Id oppId : donoPorOpp.keySet()) {
        Date dataSolic = solicitacaoPorOpp.get(oppId);
        novas.add(
          new Task(
            Subject = SUBJECT_ACOMPANHAMENTO,
            WhatId = oppId,
            OwnerId = donoPorOpp.get(oppId),
            Status = TASK_STATUS_ABERTO,
            ActivityDate = vencimentoPorSolicitacao.get(dataSolic),
            // Classificador técnico + referência estável da solicitação.
            SOL_Tipo_Tarefa__c = TIPO_TAREFA_ACOMPANHAMENTO,
            SOL_Data_Solicitacao_Calculo_Ref__c = dataSolic
          )
        );
      }
      insert novas;
      r.tarefasCriadas = novas.size();
      return r;
    } catch (AcompanhamentoCalculoException e) {
      // rollback(sp): desfaz só o trabalho deste serviço após setSavepoint().
      // O registro da data no Card 09 é desfeito pelo abort da transação quando
      // o Invocable relança esta exceção ao Flow (CurrentTransaction).
      if (sp != null) {
        Database.rollback(sp);
      }
      System.debug(LoggingLevel.ERROR, 'SOLAcompanhamentoCalculoService: ' + e.getMessage());
      throw e;
    } catch (SOLBusinessHoursHelper.CalendarioIndisponivelException e) {
      if (sp != null) {
        Database.rollback(sp);
      }
      System.debug(LoggingLevel.ERROR, 'SOLAcompanhamentoCalculoService: ' + e.getMessage());
      throw new AcompanhamentoCalculoException(MSG_SEM_CALENDARIO);
    } catch (Exception e) {
      if (sp != null) {
        Database.rollback(sp);
      }
      System.debug(
        LoggingLevel.ERROR,
        'SOLAcompanhamentoCalculoService: ' +
          e.getTypeName() +
          ': ' +
          e.getMessage() +
          '\n' +
          e.getStackTraceString()
      );
      throw new AcompanhamentoCalculoException(MSG_FALHA);
    }
  }

  private static String chave(Id oppId, Date dataSolicitacao) {
    return oppId + '|' + String.valueOf(dataSolicitacao);
  }
}
