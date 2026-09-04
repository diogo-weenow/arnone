/**
 * CLICKUP-9422 — Card 11 — Reunião final após o recebimento do cálculo jurídico.
 *
 * Quando a Task de acompanhamento do cálculo jurídico
 * (SOL_Tipo_Tarefa__c = "Acompanhamento do cálculo jurídico") muda REALMENTE
 * para "Completed", com SOL_Data_Recebimento_Calculo__c preenchida e WhatId de
 * Opportunity, o recebimento do cálculo é considerado confirmado e, para a
 * Oportunidade no escopo — Record Type SOL, produto "Recuperação Tributária",
 * etapa de origem "Diagnóstico", aberta — este serviço:
 *
 *  1. avança a Oportunidade de "Diagnóstico" para "Negociação";
 *  2. cria UMA Task "Realizar reunião final" para o proprietário atual da
 *     Oportunidade, com vencimento 7 dias ÚTEIS depois de
 *     SOL_Data_Recebimento_Calculo__c (via SOLBusinessHoursHelper — calendário
 *     da org, feriados e timezone America/Sao_Paulo; sem 7 dias corridos, sem
 *     grade fixa seg–sex, sem cópia do algoritmo).
 *
 * ART 360, outras BUs, outros tipos de Task e outras etapas ficam intactos.
 *
 * IDENTIDADE: a Task "Reunião final" guarda SOL_Data_Recebimento_Calculo_Ref__c
 * = a data de recebimento. Idempotência pela chave (Opportunity + data de
 * recebimento), consultando tarefas de QUALQUER status — reprocessamento e
 * duas entradas do mesmo registro não duplicam nem re-avançam a etapa. O
 * vencimento SEMPRE deriva da data real de recebimento (nunca Date.today()).
 *
 * ATÔMICO: avanço da etapa + criação da Task no mesmo Savepoint. Em qualquer
 * falha — inclusive os requisitos de e-CAC não satisfeitos (a VR
 * SOL_ECAC_Antes_De_Negociar e demais VRs de Negociação NÃO são enfraquecidas)
 * ou calendário ausente — o Savepoint é desfeito e o método RELANÇA
 * {@link ReuniaoFinalException}. O Invocable propaga ao Flow
 * (flowTransactionModel = CurrentTransaction), abortando a transação inteira —
 * inclusive a conclusão da Task de acompanhamento. Sem estado parcial.
 *
 * NÃO cria a tarefa de fechamento (isso é o CLICKUP-9423). NÃO apaga Tasks.
 */
public without sharing class SOLReuniaoFinalService {
  @TestVisible
  private static final String RECORD_TYPE_SOL = 'SOL';
  @TestVisible
  private static final String PRODUTO_RECUPERACAO = 'Recuperação Tributária';
  @TestVisible
  private static final String ETAPA_ORIGEM = 'Diagnóstico';
  @TestVisible
  private static final String ETAPA_DESTINO = 'Negociação';
  @TestVisible
  private static final String TIPO_ACOMPANHAMENTO = 'Acompanhamento do cálculo jurídico';
  @TestVisible
  private static final String TIPO_REUNIAO_FINAL = 'Reunião final';
  @TestVisible
  private static final String SUBJECT_REUNIAO_FINAL = 'Realizar reunião final';
  @TestVisible
  private static final String STATUS_COMPLETED = 'Completed';
  @TestVisible
  private static final String TASK_STATUS_ABERTO = 'Open';
  @TestVisible
  private static final Integer DIAS_UTEIS_PRAZO = 7;

  /** Falha ao criar a Task / avançar a etapa (a transação deve ser abortada). */
  public static final String MSG_FALHA = 'Não foi possível preparar a reunião final. Nenhuma alteração foi salva — conclua a tarefa de acompanhamento novamente.';
  /** Calendário comercial ausente. */
  public static final String MSG_SEM_CALENDARIO = 'A reunião final não foi preparada: o calendário "Arnone Soluções - Horário Comercial" não está ativo. Nenhuma alteração foi salva.';
  /** Requisitos de e-CAC (ou outras VRs de Negociação) não satisfeitos. */
  public static final String MSG_REQUISITOS_NEGOCIACAO = 'A Oportunidade não pôde avançar para Negociação: verifique os requisitos de e-CAC (consulta realizada com resultado "Valor a recuperar" e valor apurado) e corrija antes de concluir a tarefa. Nenhuma alteração foi salva.';

  /** Falha controlada da preparação da reunião final (CLICKUP-9422). */
  public class ReuniaoFinalException extends Exception {
  }

  /** Resultado controlado. */
  public class ResultadoReuniaoFinal {
    /** Oportunidades avançadas para Negociação agora. */
    public Integer oportunidadesAvancadas = 0;
    /** Tarefas "Realizar reunião final" criadas agora. */
    public Integer tarefasCriadas = 0;
    /** Tasks fora do escopo, ou cuja Opp já foi tratada / não é elegível. */
    public Integer ignorados = 0;
  }

  /**
   * Trata as Tasks de acompanhamento do cálculo que acabaram de ser concluídas.
   *
   * @param taskIds Ids de Task (qualquer origem; filtrados aqui).
   * @return contagens controladas.
   * @throws ReuniaoFinalException falha / requisitos de e-CAC / calendário
   *   ausente (a transação deve ser abortada).
   */
  public static ResultadoReuniaoFinal prepararReuniaoFinal(List<Id> taskIds) {
    ResultadoReuniaoFinal r = new ResultadoReuniaoFinal();
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

      // Trava as Tasks de acompanhamento: serializa execuções concorrentes.
      Map<Id, Date> recebimentoPorOpp = new Map<Id, Date>();
      for (Task t : [
        SELECT Id, WhatId, Status, SOL_Tipo_Tarefa__c, SOL_Data_Recebimento_Calculo__c
        FROM Task
        WHERE Id IN :ids
        FOR UPDATE
      ]) {
        Boolean noEscopo =
          t.SOL_Tipo_Tarefa__c == TIPO_ACOMPANHAMENTO &&
          t.Status == STATUS_COMPLETED &&
          t.SOL_Data_Recebimento_Calculo__c != null &&
          t.WhatId != null &&
          t.WhatId.getSObjectType() == Opportunity.SObjectType;
        if (noEscopo) {
          // Uma única solicitação/recebimento por Opp (o Card 09 nunca
          // sobrescreve a data) — o mapa por Opp é suficiente.
          recebimentoPorOpp.put(t.WhatId, t.SOL_Data_Recebimento_Calculo__c);
        }
      }
      // Tudo que não virou uma Opp no escopo (fora de escopo, sem acesso, etc.).
      r.ignorados += (ids.size() - recebimentoPorOpp.size());

      if (recebimentoPorOpp.isEmpty()) {
        return r;
      }

      // Trava as Oportunidades.
      Map<Id, Opportunity> opps = new Map<Id, Opportunity>(
        [
          SELECT Id, OwnerId, StageName, IsClosed, SOL_Produto_Negocio__c, RecordType.DeveloperName
          FROM Opportunity
          WHERE Id IN :recebimentoPorOpp.keySet()
          FOR UPDATE
        ]
      );

      // Idempotência: (Opp + data de recebimento) que já tem "Reunião final".
      Set<String> jaExiste = new Set<String>();
      for (Task t : [
        SELECT WhatId, SOL_Data_Recebimento_Calculo_Ref__c
        FROM Task
        WHERE
          WhatId IN :recebimentoPorOpp.keySet()
          AND SOL_Tipo_Tarefa__c = :TIPO_REUNIAO_FINAL
          AND SOL_Data_Recebimento_Calculo_Ref__c != null
      ]) {
        jaExiste.add(chave(t.WhatId, t.SOL_Data_Recebimento_Calculo_Ref__c));
      }

      Map<Id, Date> aProcessar = new Map<Id, Date>();
      for (Id oppId : recebimentoPorOpp.keySet()) {
        Date receb = recebimentoPorOpp.get(oppId);
        Opportunity o = opps.get(oppId);
        Boolean elegivel =
          o != null &&
          o.RecordType.DeveloperName == RECORD_TYPE_SOL &&
          o.SOL_Produto_Negocio__c == PRODUTO_RECUPERACAO &&
          o.IsClosed == false &&
          // (CLICKUP-9425) explícito: negócio perdido não avança mais.
          !SOLNegocioPerdidoService.oportunidadePerdida(o) &&
          o.StageName == ETAPA_ORIGEM;
        if (!elegivel || jaExiste.contains(chave(oppId, receb))) {
          r.ignorados++;
          continue;
        }
        aProcessar.put(oppId, receb);
      }

      if (aProcessar.isEmpty()) {
        return r;
      }

      Id bhId = SOLBusinessHoursHelper.businessHoursId();
      if (bhId == null) {
        throw new ReuniaoFinalException(MSG_SEM_CALENDARIO);
      }

      // Prazo por data de recebimento — resolvido uma vez por data distinta.
      Map<Date, Date> vencimentoPorRecebimento = new Map<Date, Date>();
      for (Date receb : aProcessar.values()) {
        if (!vencimentoPorRecebimento.containsKey(receb)) {
          Datetime prazo = SOLBusinessHoursHelper.prazoEmDiasUteis(bhId, receb, DIAS_UTEIS_PRAZO);
          vencimentoPorRecebimento.put(
            receb,
            SOLBusinessHoursHelper.dataEm(prazo, SOLBusinessHoursHelper.TZ_SAO_PAULO)
          );
        }
      }

      // 1) Avança a etapa — as VRs de Negociação (e-CAC etc.) permanecem ativas.
      List<Opportunity> avancar = new List<Opportunity>();
      for (Id oppId : aProcessar.keySet()) {
        avancar.add(new Opportunity(Id = oppId, StageName = ETAPA_DESTINO));
      }
      try {
        update avancar;
      } catch (DmlException dmle) {
        System.debug(LoggingLevel.ERROR, 'SOLReuniaoFinalService (avanço): ' + dmle.getMessage());
        throw new ReuniaoFinalException(MSG_REQUISITOS_NEGOCIACAO);
      }
      r.oportunidadesAvancadas = avancar.size();

      // 2) Cria a Task "Realizar reunião final".
      List<Task> novas = new List<Task>();
      for (Id oppId : aProcessar.keySet()) {
        Date receb = aProcessar.get(oppId);
        novas.add(
          new Task(
            Subject = SUBJECT_REUNIAO_FINAL,
            WhatId = oppId,
            OwnerId = opps.get(oppId).OwnerId,
            Status = TASK_STATUS_ABERTO,
            ActivityDate = vencimentoPorRecebimento.get(receb),
            SOL_Tipo_Tarefa__c = TIPO_REUNIAO_FINAL,
            SOL_Data_Recebimento_Calculo_Ref__c = receb
          )
        );
      }
      insert novas;
      r.tarefasCriadas = novas.size();
      return r;
    } catch (ReuniaoFinalException e) {
      if (sp != null) {
        Database.rollback(sp);
      }
      System.debug(LoggingLevel.ERROR, 'SOLReuniaoFinalService: ' + e.getMessage());
      throw e;
    } catch (SOLBusinessHoursHelper.CalendarioIndisponivelException e) {
      if (sp != null) {
        Database.rollback(sp);
      }
      System.debug(LoggingLevel.ERROR, 'SOLReuniaoFinalService: ' + e.getMessage());
      throw new ReuniaoFinalException(MSG_SEM_CALENDARIO);
    } catch (Exception e) {
      if (sp != null) {
        Database.rollback(sp);
      }
      System.debug(
        LoggingLevel.ERROR,
        'SOLReuniaoFinalService: ' +
          e.getTypeName() +
          ': ' +
          e.getMessage() +
          '\n' +
          e.getStackTraceString()
      );
      throw new ReuniaoFinalException(MSG_FALHA);
    }
  }

  private static String chave(Id oppId, Date recebimento) {
    return oppId + '|' + String.valueOf(recebimento);
  }
}
