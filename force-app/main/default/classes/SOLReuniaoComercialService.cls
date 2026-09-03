/**
 * CLICKUP-9401 — Card 07A — Criação automática da tarefa de reunião comercial.
 *
 * Quando um Lead da Arnone Soluções (Recuperação Tributária ou ART 360) entra
 * em "Reunião Agendada - SQL", cria UMA Task "Realizar reunião comercial" para
 * o proprietário atual do Lead, com vencimento 7 dias ÚTEIS depois da mudança
 * de etapa — dias úteis pelo Business Hours "Arnone Soluções - Horário
 * Comercial" (respeita fim de semana e feriados do calendário).
 *
 * Serviço dedicado (não amplia SOLDistribuicaoService). Bulk-safe: nenhuma
 * consulta ou DML em laço. Concorrência: Lead travado com FOR UPDATE.
 * Idempotência: no máximo UMA tarefa automática de reunião por Lead — verificada
 * pelo classificador SOL_Tipo_Tarefa__c = "Reunião comercial" em QUALQUER
 * status (aberta ou encerrada). Reprocessamento e reentrada não criam outra.
 *
 * ATÔMICO: em qualquer falha (inclusive calendário ausente), o Savepoint desfaz
 * tudo e o método RELANÇA {@link ReuniaoComercialException}; propagada pelo
 * Invocable, aborta a transação inteira — a mudança de etapa é desfeita junto.
 * Sem addDays(7) e sem fallback silencioso.
 *
 * NÃO altera o Status do Lead (não avança para "Procuração Solicitada"). NÃO lê
 * o Event: a data da reunião não substitui o prazo — prevalecem os 7 dias úteis.
 */
public without sharing class SOLReuniaoComercialService {
  @TestVisible
  private static final String RECORD_TYPE_SOL = 'SOL';
  @TestVisible
  private static final String STATUS_REUNIAO_SQL = 'Reunião Agendada - SQL';
  @TestVisible
  private static final String PRODUTO_RECUPERACAO = 'Recuperação Tributária';
  @TestVisible
  private static final String PRODUTO_ART = 'ART 360';
  @TestVisible
  private static final String SUBJECT_REUNIAO = 'Realizar reunião comercial';
  @TestVisible
  private static final String TIPO_TAREFA_REUNIAO = 'Reunião comercial';
  @TestVisible
  private static final String TASK_STATUS_ABERTO = 'Open';
  @TestVisible
  private static final Integer DIAS_UTEIS_PRAZO = 7;
  @TestVisible
  private static final String BUSINESS_HOURS_NAME = 'Arnone Soluções - Horário Comercial';

  /** Mensagem controlada exibida ao vendedor quando a criação da tarefa falha. */
  public static final String MSG_FALHA = 'Não foi possível criar a tarefa de reunião comercial. Nenhuma alteração foi salva — tente registrar a reunião novamente.';
  /** Mensagem controlada quando o calendário comercial não está configurado. */
  public static final String MSG_SEM_CALENDARIO = 'A tarefa de reunião comercial não foi criada: o calendário "Arnone Soluções - Horário Comercial" não está ativo. Nenhuma alteração foi salva.';

  /** Falha controlada da criação da tarefa de reunião (CLICKUP-9401). */
  public class ReuniaoComercialException extends Exception {
  }

  /** Resultado controlado da criação da tarefa de reunião comercial. */
  public class ResultadoReuniaoComercial {
    /** Tarefas de reunião comercial criadas agora. */
    public Integer tarefasCriadas = 0;
    /** Leads fora do escopo (outro RT/produto, convertido, opt-out, status ≠ SQL) ou que já tinham a tarefa. */
    public Integer ignorados = 0;
  }

  private static Id bhCache;
  private static Boolean bhResolvido = false;

  /**
   * Cria a Task "Realizar reunião comercial" para os Leads que acabaram de
   * entrar em "Reunião Agendada - SQL".
   *
   * @param leadIds Ids de Lead (qualquer origem; filtrados aqui).
   * @return contagens controladas.
   * @throws ReuniaoComercialException falha ao criar / calendário ausente
   *   (a transação deve ser abortada).
   */
  public static ResultadoReuniaoComercial criarTarefaReuniao(List<Id> leadIds) {
    ResultadoReuniaoComercial r = new ResultadoReuniaoComercial();
    if (leadIds == null || leadIds.isEmpty()) {
      return r;
    }

    Set<Id> ids = new Set<Id>(leadIds);
    Datetime mudanca = System.now();

    Savepoint sp = null;
    try {
      sp = Database.setSavepoint();

      // Trava os Leads: serializa duas transições concorrentes do mesmo Lead.
      List<Lead> carregados = [
        SELECT
          Id,
          OwnerId,
          Status,
          IsConverted,
          SOL_Opt_Out__c,
          SOL_Produto_Interesse__c,
          RecordType.DeveloperName
        FROM Lead
        WHERE Id IN :ids
        FOR UPDATE
      ];

      Map<Id, Id> donoPorLead = new Map<Id, Id>();
      Set<Id> encontrados = new Set<Id>();
      for (Lead l : carregados) {
        encontrados.add(l.Id);
        Boolean elegivel =
          l.RecordType.DeveloperName == RECORD_TYPE_SOL &&
          l.Status == STATUS_REUNIAO_SQL &&
          l.IsConverted == false &&
          l.SOL_Opt_Out__c != true &&
          (l.SOL_Produto_Interesse__c == PRODUTO_RECUPERACAO ||
          l.SOL_Produto_Interesse__c == PRODUTO_ART);
        if (elegivel) {
          donoPorLead.put(l.Id, l.OwnerId);
        } else {
          r.ignorados++;
        }
      }
      r.ignorados += (ids.size() - encontrados.size());

      if (donoPorLead.isEmpty()) {
        return r;
      }

      // Idempotência: no máximo UMA tarefa automática de reunião por Lead.
      // Conta tarefas de QUALQUER status (aberta ou encerrada).
      for (Task t : [
        SELECT WhoId
        FROM Task
        WHERE
          WhoId IN :donoPorLead.keySet()
          AND SOL_Tipo_Tarefa__c = :TIPO_TAREFA_REUNIAO
      ]) {
        if (donoPorLead.containsKey(t.WhoId)) {
          donoPorLead.remove(t.WhoId);
          r.ignorados++;
        }
      }

      if (donoPorLead.isEmpty()) {
        return r;
      }

      Id bhId = businessHoursComercialId();
      if (bhId == null) {
        throw new ReuniaoComercialException(MSG_SEM_CALENDARIO);
      }
      Datetime prazo = prazoEmDiasUteis(bhId, mudanca, DIAS_UTEIS_PRAZO);

      List<Task> novas = new List<Task>();
      for (Id leadId : donoPorLead.keySet()) {
        novas.add(
          new Task(
            Subject = SUBJECT_REUNIAO,
            WhoId = leadId,
            OwnerId = donoPorLead.get(leadId),
            Status = TASK_STATUS_ABERTO,
            ActivityDate = prazo.dateGmt(),
            // Classificador técnico — chave de idempotência (nunca o Subject).
            SOL_Tipo_Tarefa__c = TIPO_TAREFA_REUNIAO
          )
        );
      }
      insert novas;
      r.tarefasCriadas = novas.size();
      return r;
    } catch (ReuniaoComercialException e) {
      if (sp != null) {
        Database.rollback(sp);
      }
      System.debug(LoggingLevel.ERROR, 'SOLReuniaoComercialService: ' + e.getMessage());
      throw e;
    } catch (Exception e) {
      if (sp != null) {
        Database.rollback(sp);
      }
      System.debug(
        LoggingLevel.ERROR,
        'SOLReuniaoComercialService: ' +
          e.getTypeName() +
          ': ' +
          e.getMessage() +
          '\n' +
          e.getStackTraceString()
      );
      throw new ReuniaoComercialException(MSG_FALHA);
    }
  }

  /**
   * Datetime `dias` dias ÚTEIS depois de `origem`, contados pelo Business Hours
   * `bhId` — respeita a grade semanal e os feriados do calendário. Sem
   * addDays(7): normaliza a origem para dentro do expediente e avança um dia de
   * calendário por vez, contando só os que caem em dia útil.
   */
  @TestVisible
  private static Datetime prazoEmDiasUteis(Id bhId, Datetime origem, Integer dias) {
    // +1 ms de tempo útil: se `origem` está fora do expediente, salta para o
    // próximo período útil; o horário resultante fica dentro do expediente.
    Datetime prazo = BusinessHours.add(bhId, origem, 1);
    Integer contados = 0;
    Integer guarda = 0;
    while (contados < dias && guarda < 400) {
      prazo = prazo.addDays(1);
      if (BusinessHours.isWithin(bhId, prazo)) {
        contados++;
      }
      guarda++;
    }
    if (contados < dias) {
      // Calendário sem dias úteis suficientes — trata como calendário inválido.
      throw new ReuniaoComercialException(MSG_SEM_CALENDARIO);
    }
    return prazo;
  }

  /**
   * Id do Business Hours "Arnone Soluções - Horário Comercial" (ativo), ou null
   * se não existir / não estiver ativo. Resolvido uma única vez por transação.
   */
  @TestVisible
  private static Id businessHoursComercialId() {
    if (!bhResolvido) {
      List<BusinessHours> bhs = [
        SELECT Id
        FROM BusinessHours
        WHERE Name = :BUSINESS_HOURS_NAME AND IsActive = true
        LIMIT 1
      ];
      bhCache = bhs.isEmpty() ? null : bhs[0].Id;
      bhResolvido = true;
    }
    return bhCache;
  }

  /** Só para testes: força o cache do Business Hours (ex.: calendário ausente). */
  @TestVisible
  private static void forcarBusinessHours(Id valor) {
    bhCache = valor;
    bhResolvido = true;
  }
}
