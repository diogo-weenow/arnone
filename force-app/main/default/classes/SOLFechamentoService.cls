/**
 * CLICKUP-9423 — Card 12 — Tarefa de fechamento.
 *
 * DOIS eventos isolados da jornada Arnone Soluções (Record Type SOL, produto
 * "Recuperação Tributária"). ART 360 e outras BUs ficam intactas.
 *
 * EVENTO 1 — criarTarefaFechamento(taskIds):
 *   Quando a Task "Reunião final" (SOL_Tipo_Tarefa__c = "Reunião final") muda
 *   REALMENTE para "Completed", com SOL_Data_Reuniao_Final__c preenchida e
 *   WhatId de Opportunity em "Negociação", cria UMA Task "Realizar fechamento"
 *   para o proprietário atual da Oportunidade, com vencimento 7 dias ÚTEIS
 *   depois de SOL_Data_Reuniao_Final__c (via SOLBusinessHoursHelper — calendário
 *   da org, feriados, timezone America/Sao_Paulo). A Oportunidade permanece em
 *   "Negociação" — este serviço NÃO muda etapa aqui.
 *   IDENTIDADE: a Task guarda SOL_Data_Reuniao_Final_Ref__c = a data da reunião.
 *   Idempotência (Opportunity + tipo "Fechamento" + data da reunião), tarefas de
 *   QUALQUER status. Vencimento SEMPRE da data real da reunião (nunca hoje).
 *   ATÔMICO: em falha, o Savepoint é desfeito e o método RELANÇA
 *   FechamentoException; o Invocable propaga ao Flow (CurrentTransaction),
 *   abortando a transação — inclusive a conclusão da Task de reunião final.
 *
 * EVENTO 2 — encerrarTarefasFechamento(opportunityIds):
 *   Quando a Oportunidade muda REALMENTE para "Ganho", conclui
 *   automaticamente TODAS as Tasks abertas do tipo "Fechamento" dela, gravando
 *   Status = "Completed" e SOL_Encerrado_Pela_Oportunidade__c = true
 *   na MESMA atualização. É esse checkbox técnico que autoriza a transição na VR
 *   SOL_Fechamento_Exige_Encerramento_Auto: sem ele, a conclusão MANUAL da Task
 *   de fechamento (com a Oportunidade ainda aberta) é bloqueada. Não altera
 *   outras Tasks. Se não houver tarefa de fechamento, a mudança da Oportunidade
 *   segue normalmente. As Validation Rules de Ganho/Perdido são preservadas (o
 *   Flow é after-save: só roda se a mudança já passou pelas VRs).
 *   ATÔMICO: se a conclusão das Tasks falhar, o Savepoint é desfeito e o método
 *   RELANÇA FechamentoException; o Invocable propaga ao Flow (CurrentTransaction),
 *   abortando a mudança da Oportunidade com mensagem controlada.
 *
 *   CLICKUP-9425 — PRECEDÊNCIA EM "PERDIDO": este evento NÃO age mais em
 *   "Perdido". Lá quem age é SOLNegocioPerdidoService, que CANCELA todas as
 *   Tasks abertas da Oportunidade (inclusive a de fechamento e as manuais), com
 *   motivo "Negócio perdido" e SOL_Cancelada_Por_Perda__c. Assim a tarefa de
 *   fechamento de um negócio perdido nunca aparece como "executada". O
 *   comportamento de "Ganho" segue idêntico ao do CLICKUP-9423.
 *
 * Bulk-safe: nenhuma consulta/DML em laço. FOR UPDATE nas Tasks e Oportunidades.
 * NÃO apaga registros. NÃO antecipa reatribuição de 30 dias, cancelamento geral
 * de tarefas nem cards posteriores.
 */
public without sharing class SOLFechamentoService {
  @TestVisible
  private static final String RECORD_TYPE_SOL = 'SOL';
  @TestVisible
  private static final String PRODUTO_RECUPERACAO = 'Recuperação Tributária';
  @TestVisible
  private static final String ETAPA_NEGOCIACAO = 'Negociação';
  @TestVisible
  private static final String TIPO_REUNIAO_FINAL = 'Reunião final';
  @TestVisible
  private static final String TIPO_FECHAMENTO = 'Fechamento';
  @TestVisible
  private static final String SUBJECT_FECHAMENTO = 'Realizar fechamento';
  @TestVisible
  private static final String STATUS_COMPLETED = 'Completed';
  @TestVisible
  private static final String TASK_STATUS_ABERTO = 'Open';
  @TestVisible
  private static final Integer DIAS_UTEIS_PRAZO = 7;
  /**
   * Etapa que CONCLUI a tarefa de fechamento. CLICKUP-9425 removeu "Perdido"
   * daqui: em perda a tarefa passou a ser CANCELADA por
   * SOLNegocioPerdidoService (Status "Cancelada" + motivo "Negócio perdido" +
   * SOL_Cancelada_Por_Perda__c), nunca concluída. "Ganho" mantém integralmente o
   * comportamento do CLICKUP-9423.
   */
  @TestVisible
  private static final Set<String> ETAPAS_ENCERRAMENTO = new Set<String>{ 'Ganho' };

  /** Falha ao criar a tarefa de fechamento (a transação deve ser abortada). */
  public static final String MSG_FALHA_CRIAR = 'Não foi possível criar a tarefa de fechamento. Nenhuma alteração foi salva — conclua a reunião final novamente.';
  /** Calendário comercial ausente. */
  public static final String MSG_SEM_CALENDARIO = 'A tarefa de fechamento não foi criada: o calendário "Arnone Soluções - Horário Comercial" não está ativo. Nenhuma alteração foi salva.';
  /** Falha ao concluir a(s) tarefa(s) de fechamento (a mudança da Opp é abortada). */
  public static final String MSG_FALHA_ENCERRAR = 'Não foi possível concluir a(s) tarefa(s) de fechamento. A mudança da Oportunidade foi cancelada — tente novamente.';

  /** Falha controlada da automação de fechamento (CLICKUP-9423). */
  public class FechamentoException extends Exception {
  }

  /** Resultado controlado da criação da tarefa de fechamento (Evento 1). */
  public class ResultadoCriar {
    public Integer tarefasCriadas = 0;
    public Integer ignorados = 0;
  }

  /** Resultado controlado do encerramento das tarefas de fechamento (Evento 2). */
  public class ResultadoEncerrar {
    public Integer tarefasConcluidas = 0;
    public Integer oportunidades = 0;
  }

  // ================================================================ EVENTO 1

  /**
   * Cria a Task "Realizar fechamento" para as Tasks "Reunião final" recém
   * concluídas.
   *
   * @param taskIds Ids de Task (qualquer origem; filtrados aqui).
   * @throws FechamentoException falha / calendário ausente (aborta a transação).
   */
  public static ResultadoCriar criarTarefaFechamento(List<Id> taskIds) {
    ResultadoCriar r = new ResultadoCriar();
    if (taskIds == null || taskIds.isEmpty()) {
      return r;
    }

    Set<Id> ids = new Set<Id>();
    for (Id tid : taskIds) {
      if (tid != null && tid.getSObjectType() == Task.SObjectType) {
        ids.add(tid);
      }
    }
    if (ids.isEmpty()) {
      return r;
    }

    Savepoint sp = null;
    try {
      sp = Database.setSavepoint();

      // Trava as Tasks de reunião final: serializa execuções concorrentes.
      Map<Id, Date> reuniaoPorOpp = new Map<Id, Date>();
      for (Task t : [
        SELECT Id, WhatId, Status, SOL_Tipo_Tarefa__c, SOL_Data_Reuniao_Final__c
        FROM Task
        WHERE Id IN :ids
        FOR UPDATE
      ]) {
        Boolean noEscopo =
          t.SOL_Tipo_Tarefa__c == TIPO_REUNIAO_FINAL &&
          t.Status == STATUS_COMPLETED &&
          t.SOL_Data_Reuniao_Final__c != null &&
          t.WhatId != null &&
          t.WhatId.getSObjectType() == Opportunity.SObjectType;
        if (noEscopo) {
          reuniaoPorOpp.put(t.WhatId, t.SOL_Data_Reuniao_Final__c);
        }
      }
      r.ignorados += (ids.size() - reuniaoPorOpp.size());

      if (reuniaoPorOpp.isEmpty()) {
        return r;
      }

      Map<Id, Opportunity> opps = new Map<Id, Opportunity>(
        [
          SELECT Id, OwnerId, StageName, IsClosed, SOL_Produto_Negocio__c, RecordType.DeveloperName
          FROM Opportunity
          WHERE Id IN :reuniaoPorOpp.keySet()
          FOR UPDATE
        ]
      );

      // Idempotência: (Opp + data da reunião) que já tem "Fechamento".
      Set<String> jaExiste = new Set<String>();
      for (Task t : [
        SELECT WhatId, SOL_Data_Reuniao_Final_Ref__c
        FROM Task
        WHERE
          WhatId IN :reuniaoPorOpp.keySet()
          AND SOL_Tipo_Tarefa__c = :TIPO_FECHAMENTO
          AND SOL_Data_Reuniao_Final_Ref__c != null
      ]) {
        jaExiste.add(chave(t.WhatId, t.SOL_Data_Reuniao_Final_Ref__c));
      }

      Map<Id, Date> aProcessar = new Map<Id, Date>();
      for (Id oppId : reuniaoPorOpp.keySet()) {
        Date reuniao = reuniaoPorOpp.get(oppId);
        Opportunity o = opps.get(oppId);
        Boolean elegivel =
          o != null &&
          o.RecordType.DeveloperName == RECORD_TYPE_SOL &&
          o.SOL_Produto_Negocio__c == PRODUTO_RECUPERACAO &&
          o.IsClosed == false &&
          // (CLICKUP-9425) explícito: negócio perdido não avança mais.
          !SOLNegocioPerdidoService.oportunidadePerdida(o) &&
          o.StageName == ETAPA_NEGOCIACAO;
        if (!elegivel || jaExiste.contains(chave(oppId, reuniao))) {
          r.ignorados++;
          continue;
        }
        aProcessar.put(oppId, reuniao);
      }

      if (aProcessar.isEmpty()) {
        return r;
      }

      Id bhId = SOLBusinessHoursHelper.businessHoursId();
      if (bhId == null) {
        throw new FechamentoException(MSG_SEM_CALENDARIO);
      }

      Map<Date, Date> vencimentoPorReuniao = new Map<Date, Date>();
      for (Date reuniao : aProcessar.values()) {
        if (!vencimentoPorReuniao.containsKey(reuniao)) {
          Datetime prazo = SOLBusinessHoursHelper.prazoEmDiasUteis(bhId, reuniao, DIAS_UTEIS_PRAZO);
          vencimentoPorReuniao.put(
            reuniao,
            SOLBusinessHoursHelper.dataEm(prazo, SOLBusinessHoursHelper.TZ_SAO_PAULO)
          );
        }
      }

      List<Task> novas = new List<Task>();
      for (Id oppId : aProcessar.keySet()) {
        Date reuniao = aProcessar.get(oppId);
        novas.add(
          new Task(
            Subject = SUBJECT_FECHAMENTO,
            WhatId = oppId,
            OwnerId = opps.get(oppId).OwnerId,
            Status = TASK_STATUS_ABERTO,
            ActivityDate = vencimentoPorReuniao.get(reuniao),
            SOL_Tipo_Tarefa__c = TIPO_FECHAMENTO,
            SOL_Data_Reuniao_Final_Ref__c = reuniao
          )
        );
      }
      insert novas;
      r.tarefasCriadas = novas.size();
      return r;
    } catch (FechamentoException e) {
      if (sp != null) {
        Database.rollback(sp);
      }
      System.debug(LoggingLevel.ERROR, 'SOLFechamentoService.criar: ' + e.getMessage());
      throw e;
    } catch (SOLBusinessHoursHelper.CalendarioIndisponivelException e) {
      if (sp != null) {
        Database.rollback(sp);
      }
      System.debug(LoggingLevel.ERROR, 'SOLFechamentoService.criar: ' + e.getMessage());
      throw new FechamentoException(MSG_SEM_CALENDARIO);
    } catch (Exception e) {
      if (sp != null) {
        Database.rollback(sp);
      }
      System.debug(
        LoggingLevel.ERROR,
        'SOLFechamentoService.criar: ' +
          e.getTypeName() +
          ': ' +
          e.getMessage() +
          '\n' +
          e.getStackTraceString()
      );
      throw new FechamentoException(MSG_FALHA_CRIAR);
    }
  }

  // ================================================================ EVENTO 2

  /**
   * Conclui todas as Tasks abertas do tipo "Fechamento" das Oportunidades que
   * acabaram de virar "Ganho".
   *
   * CLICKUP-9425: "Perdido" não entra mais aqui — ver ETAPAS_ENCERRAMENTO.
   *
   * @param opportunityIds Ids de Opportunity (qualquer origem; filtrados aqui).
   * @throws FechamentoException falha ao concluir as Tasks (aborta a mudança da
   *   Oportunidade).
   */
  public static ResultadoEncerrar encerrarTarefasFechamento(List<Id> opportunityIds) {
    ResultadoEncerrar r = new ResultadoEncerrar();
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

      Set<Id> elegiveis = new Set<Id>();
      for (Opportunity o : [
        SELECT Id, StageName, SOL_Produto_Negocio__c, RecordType.DeveloperName
        FROM Opportunity
        WHERE Id IN :ids
        FOR UPDATE
      ]) {
        if (
          o.RecordType.DeveloperName == RECORD_TYPE_SOL &&
          o.SOL_Produto_Negocio__c == PRODUTO_RECUPERACAO &&
          ETAPAS_ENCERRAMENTO.contains(o.StageName)
        ) {
          elegiveis.add(o.Id);
        }
      }
      if (elegiveis.isEmpty()) {
        return r;
      }

      List<Task> abertas = [
        SELECT Id, WhatId
        FROM Task
        WHERE
          WhatId IN :elegiveis
          AND SOL_Tipo_Tarefa__c = :TIPO_FECHAMENTO
          AND IsClosed = false
        FOR UPDATE
      ];
      if (abertas.isEmpty()) {
        // Sem tarefa de fechamento: a mudança da Oportunidade segue normalmente.
        return r;
      }

      Set<Id> oppsComTarefa = new Set<Id>();
      List<Task> concluir = new List<Task>();
      for (Task t : abertas) {
        // Status e o checkbox técnico gravados SIMULTANEAMENTE: é o checkbox que
        // autoriza a transição para "Completed" na VR
        // SOL_Fechamento_Exige_Encerramento_Auto — a conclusão manual, com a
        // Oportunidade ainda aberta, fica bloqueada.
        concluir.add(
          new Task(
            Id = t.Id,
            Status = STATUS_COMPLETED,
            SOL_Encerrado_Pela_Oportunidade__c = true
          )
        );
        oppsComTarefa.add(t.WhatId);
      }
      update concluir;
      r.tarefasConcluidas = concluir.size();
      r.oportunidades = oppsComTarefa.size();
      return r;
    } catch (Exception e) {
      if (sp != null) {
        Database.rollback(sp);
      }
      System.debug(
        LoggingLevel.ERROR,
        'SOLFechamentoService.encerrar: ' +
          e.getTypeName() +
          ': ' +
          e.getMessage() +
          '\n' +
          e.getStackTraceString()
      );
      throw new FechamentoException(MSG_FALHA_ENCERRAR);
    }
  }

  private static String chave(Id oppId, Date reuniao) {
    return oppId + '|' + String.valueOf(reuniao);
  }
}
