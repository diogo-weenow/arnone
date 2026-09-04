/**
 * CLICKUP-9426 — Card 07B — Criação automática da tarefa de acompanhamento da
 * procuração.
 *
 * Quando um Lead da Arnone Soluções registra EFETIVAMENTE uma solicitação de
 * procuração — os três sinais juntos: Status = "Procuração Solicitada",
 * SOL_Status_Procuracao__c = "Solicitada" e SOL_Data_Solicitacao_Procuracao__c
 * preenchida — cria UMA Task "Acompanhar recebimento da procuração" para o
 * proprietário atual do Lead, com vencimento 7 dias ÚTEIS depois da data da
 * solicitação. Vale para Recuperação Tributária E ART 360 (a procuração é
 * obrigatória nos dois — coerente com SOL_Procuracao e SOL_ConverterLead; esta
 * decisão substitui a restrição do PDF).
 *
 * Serviço dedicado. Bulk-safe: nenhuma consulta/DML em laço. Concorrência: Lead
 * travado com FOR UPDATE. Dias úteis / feriados / timezone: SOLBusinessHoursHelper
 * (mesma lógica do CLICKUP-9401).
 *
 * IDENTIDADE DA SOLICITAÇÃO: a Task guarda SOL_Data_Solicitacao_Ref__c = a data
 * registrada no Lead. Idempotência pela chave (Lead + data da solicitação),
 * consultando tarefas de QUALQUER status:
 *  - reprocessamento / reentrada para a MESMA solicitação não duplica (mesmo com
 *    a tarefa anterior encerrada);
 *  - uma NOVA solicitação, com nova data, pode gerar uma nova tarefa;
 *  - no máximo uma tarefa por Lead e por solicitação.
 *
 * ATÔMICO: em qualquer falha (inclusive calendário ausente), o Savepoint desfaz
 * o trabalho feito DENTRO deste serviço após a sua criação (as queries com
 * lock e o insert das Tasks) e o método RELANÇA {@link AcompanhamentoException}.
 * O registro anterior da solicitação (Status + campos do Lead), feito pela
 * atualização que disparou o Flow, é desfeito porque a exceção é propagada pelo
 * Invocable ao Flow (flowTransactionModel = CurrentTransaction), abortando a
 * transação completa — não pelo rollback do Savepoint. Resultado: sem estado
 * parcial. Sem 7 dias corridos, sem grade fixa seg–sex e sem fallback
 * silencioso.
 *
 * NÃO altera o Status do Lead. NÃO trata recebimento/conversão da procuração
 * nem encerra a tarefa no recebimento (fora do escopo do card).
 */
public without sharing class SOLProcuracaoAcompanhamentoService {
  @TestVisible
  private static final String RECORD_TYPE_SOL = 'SOL';
  @TestVisible
  private static final String STATUS_PROCURACAO_SOLICITADA = 'Procuração Solicitada';
  @TestVisible
  private static final String STATUS_PROC_CAMPO_SOLICITADA = 'Solicitada';
  @TestVisible
  private static final String PRODUTO_RECUPERACAO = 'Recuperação Tributária';
  @TestVisible
  private static final String PRODUTO_ART = 'ART 360';
  @TestVisible
  private static final String SUBJECT_ACOMPANHAMENTO = 'Acompanhar recebimento da procuração';
  @TestVisible
  private static final String TIPO_TAREFA_ACOMPANHAMENTO = 'Acompanhamento da procuração';
  @TestVisible
  private static final String TASK_STATUS_ABERTO = 'Open';
  @TestVisible
  private static final Integer DIAS_UTEIS_PRAZO = 7;

  /** Mensagem controlada exibida ao vendedor quando a criação da tarefa falha. */
  public static final String MSG_FALHA = 'Não foi possível criar a tarefa de acompanhamento da procuração. Nenhuma alteração foi salva — registre a solicitação novamente.';
  /** Mensagem controlada quando o calendário comercial não está configurado. */
  public static final String MSG_SEM_CALENDARIO = 'A tarefa de acompanhamento da procuração não foi criada: o calendário "Arnone Soluções - Horário Comercial" não está ativo. Nenhuma alteração foi salva.';

  /** Falha controlada da criação da tarefa de acompanhamento (CLICKUP-9426). */
  public class AcompanhamentoException extends Exception {
  }

  /** Resultado controlado da criação da tarefa de acompanhamento da procuração. */
  public class ResultadoAcompanhamento {
    /** Tarefas de acompanhamento criadas agora. */
    public Integer tarefasCriadas = 0;
    /** Leads fora do escopo, sem solicitação válida, ou que já tinham a tarefa desta solicitação. */
    public Integer ignorados = 0;
  }

  /**
   * Cria a Task "Acompanhar recebimento da procuração" para os Leads que
   * acabaram de registrar a solicitação da procuração.
   *
   * Em caso de falha: o Savepoint desfaz o que este serviço fez após criá-lo e
   * a {@link AcompanhamentoException} é relançada; o Invocable a propaga ao Flow
   * (CurrentTransaction), que aborta a transação inteira — é isso que desfaz a
   * atualização anterior do Lead (o registro da solicitação).
   *
   * @param leadIds Ids de Lead (qualquer origem; filtrados aqui).
   * @return contagens controladas.
   * @throws AcompanhamentoException falha ao criar / calendário ausente
   *   (a transação deve ser abortada).
   */
  public static ResultadoAcompanhamento criarTarefaAcompanhamento(List<Id> leadIds) {
    ResultadoAcompanhamento r = new ResultadoAcompanhamento();
    if (leadIds == null || leadIds.isEmpty()) {
      return r;
    }

    Set<Id> ids = new Set<Id>(leadIds);

    Savepoint sp = null;
    try {
      sp = Database.setSavepoint();

      // Trava os Leads: serializa duas execuções concorrentes do mesmo Lead.
      List<Lead> carregados = [
        SELECT
          Id,
          OwnerId,
          Status,
          IsConverted,
          SOL_Produto_Interesse__c,
          SOL_Status_Procuracao__c,
          SOL_Data_Solicitacao_Procuracao__c,
          RecordType.DeveloperName,
          SOL_Motivo_Desqualificacao__c,
          SOL_Opt_Out__c
        FROM Lead
        WHERE Id IN :ids
        FOR UPDATE
      ];

      Map<Id, Id> donoPorLead = new Map<Id, Id>();
      Map<Id, Date> solicitacaoPorLead = new Map<Id, Date>();
      Set<Id> encontrados = new Set<Id>();
      for (Lead l : carregados) {
        encontrados.add(l.Id);
        Boolean solicitacaoValida =
          l.RecordType.DeveloperName == RECORD_TYPE_SOL &&
          l.IsConverted == false &&
          // (CLICKUP-9425) e o negócio ainda não foi perdido.
          !SOLNegocioPerdidoService.leadPerdido(l) &&

          l.Status == STATUS_PROCURACAO_SOLICITADA &&
          l.SOL_Status_Procuracao__c == STATUS_PROC_CAMPO_SOLICITADA &&
          l.SOL_Data_Solicitacao_Procuracao__c != null &&
          (l.SOL_Produto_Interesse__c == PRODUTO_RECUPERACAO ||
          l.SOL_Produto_Interesse__c == PRODUTO_ART);
        if (solicitacaoValida) {
          donoPorLead.put(l.Id, l.OwnerId);
          solicitacaoPorLead.put(l.Id, l.SOL_Data_Solicitacao_Procuracao__c);
        } else {
          r.ignorados++;
        }
      }
      r.ignorados += (ids.size() - encontrados.size());

      if (donoPorLead.isEmpty()) {
        return r;
      }

      // Idempotência pela chave (Lead + data da solicitação), QUALQUER status.
      Set<String> jaExiste = new Set<String>();
      for (Task t : [
        SELECT WhoId, SOL_Data_Solicitacao_Ref__c
        FROM Task
        WHERE
          WhoId IN :donoPorLead.keySet()
          AND SOL_Tipo_Tarefa__c = :TIPO_TAREFA_ACOMPANHAMENTO
          AND SOL_Data_Solicitacao_Ref__c != null
      ]) {
        jaExiste.add(chave(t.WhoId, t.SOL_Data_Solicitacao_Ref__c));
      }
      for (Id leadId : new Set<Id>(donoPorLead.keySet())) {
        if (jaExiste.contains(chave(leadId, solicitacaoPorLead.get(leadId)))) {
          donoPorLead.remove(leadId);
          r.ignorados++;
        }
      }

      if (donoPorLead.isEmpty()) {
        return r;
      }

      Id bhId = SOLBusinessHoursHelper.businessHoursId();
      if (bhId == null) {
        throw new AcompanhamentoException(MSG_SEM_CALENDARIO);
      }

      // Prazo por data de solicitação — resolvido uma vez por data distinta.
      Map<Date, Date> vencimentoPorSolicitacao = new Map<Date, Date>();
      for (Id leadId : donoPorLead.keySet()) {
        Date dataSolic = solicitacaoPorLead.get(leadId);
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
      for (Id leadId : donoPorLead.keySet()) {
        Date dataSolic = solicitacaoPorLead.get(leadId);
        novas.add(
          new Task(
            Subject = SUBJECT_ACOMPANHAMENTO,
            WhoId = leadId,
            OwnerId = donoPorLead.get(leadId),
            Status = TASK_STATUS_ABERTO,
            ActivityDate = vencimentoPorSolicitacao.get(dataSolic),
            // Classificador técnico + referência estável da solicitação.
            SOL_Tipo_Tarefa__c = TIPO_TAREFA_ACOMPANHAMENTO,
            SOL_Data_Solicitacao_Ref__c = dataSolic
          )
        );
      }
      insert novas;
      r.tarefasCriadas = novas.size();
      return r;
    } catch (AcompanhamentoException e) {
      // rollback(sp): desfaz só o trabalho deste serviço após setSavepoint().
      // A atualização anterior do Lead é desfeita pelo abort da transação
      // quando o Invocable relança esta exceção ao Flow (CurrentTransaction).
      if (sp != null) {
        Database.rollback(sp);
      }
      System.debug(LoggingLevel.ERROR, 'SOLProcuracaoAcompanhamentoService: ' + e.getMessage());
      throw e;
    } catch (SOLBusinessHoursHelper.CalendarioIndisponivelException e) {
      if (sp != null) {
        Database.rollback(sp);
      }
      System.debug(LoggingLevel.ERROR, 'SOLProcuracaoAcompanhamentoService: ' + e.getMessage());
      throw new AcompanhamentoException(MSG_SEM_CALENDARIO);
    } catch (Exception e) {
      if (sp != null) {
        Database.rollback(sp);
      }
      System.debug(
        LoggingLevel.ERROR,
        'SOLProcuracaoAcompanhamentoService: ' +
          e.getTypeName() +
          ': ' +
          e.getMessage() +
          '\n' +
          e.getStackTraceString()
      );
      throw new AcompanhamentoException(MSG_FALHA);
    }
  }

  private static String chave(Id leadId, Date dataSolicitacao) {
    return leadId + '|' + String.valueOf(dataSolicitacao);
  }
}
