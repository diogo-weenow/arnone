/**
 * CLICKUP-9398 — agendador do motor da cadência de contato SOL.
 *
 * Dispara `SOLCadenciaMotorBatch` a cada hora, no minuto 15. Nome de job ÚNICO
 * e horário distinto dos dois agendamentos que já existem: reprocessamento da
 * distribuição no minuto 0 (CLICKUP-9394) e prazo total no minuto 30
 * (CLICKUP-9424). Os três nunca disparam no mesmo instante e não disputam o
 * singleton entre si.
 *
 * POR QUE DE HORA EM HORA, se a cadência é DIÁRIA: o efeito continua sendo, no
 * máximo, uma tarefa por Lead, ciclo, canal e dia — a idempotência é do núcleo
 * (CLICKUP-9434/9435/9436), não da frequência. A repetição horária serve a duas
 * coisas que uma execução diária não entrega:
 *
 * 1. o Lead atribuído DEPOIS da varredura anterior recebe os canais do seu dia 1
 *    ainda no mesmo dia, em vez de esperar até amanhã;
 * 2. uma janela que falhe é recuperada na hora seguinte, sem intervenção.
 *
 * O agendamento NÃO é criado automaticamente (sem inicializador estático, sem
 * trigger): use `SOLCadenciaMotorScheduler.agendar()` de forma controlada
 * (Apex anônimo / Setup) — ver runbook de deploy.
 */
public without sharing class SOLCadenciaMotorScheduler implements Schedulable {
  /** Nome único do Scheduled Job. */
  public static final String NOME_JOB = 'SOL Cadencia - Motor de contato diario (hora em hora)';

  /**
   * De hora em hora, no minuto 15. Minutos 0 e 30 já estão ocupados pelos
   * agendamentos do CLICKUP-9394 e do CLICKUP-9424.
   */
  public static final String CRON_HORARIO = '0 15 * * * ?';

  /**
   * Tamanho de lote da varredura. Cada transação do Batch trava os Leads do
   * lote uma vez por canal e, quando há esgotados, também o singleton — então
   * um lote menor que o padrão de 200 encurta a janela de lock disputada com a
   * distribuição e limita o estrago de um rollback a 50 Leads, que a varredura
   * seguinte recupera por idempotência.
   */
  public static final Integer TAMANHO_LOTE = 50;

  /** Estados de AsyncApexJob que significam "ainda vai rodar ou está rodando". */
  @TestVisible
  private static final Set<String> ESTADOS_ENCERRADOS = new Set<String>{
    'Completed',
    'Aborted',
    'Failed'
  };

  public class AgendamentoException extends Exception {
  }

  public void execute(SchedulableContext sc) {
    // SOBREPOSIÇÃO: se a varredura anterior ainda não terminou, esta janela é
    // PULADA em vez de enfileirar uma segunda passagem sobre os mesmos Leads.
    // Duas execuções simultâneas não criariam duplicata — o lock do Lead e a
    // chave de idempotência do núcleo cuidam disso —, mas disputariam os mesmos
    // registros e o mesmo singleton sem entregar nada de novo.
    if (haExecucaoEmAndamento()) {
      System.debug(
        LoggingLevel.INFO,
        'SOLCadenciaMotorScheduler: varredura anterior ainda em andamento; ' +
          'esta janela foi pulada.'
      );
      return;
    }
    Database.executeBatch(new SOLCadenciaMotorBatch(), TAMANHO_LOTE);
  }

  /**
   * Já existe um lote desta varredura enfileirado, preparando ou processando?
   *
   * Pergunta pelo NEGATIVO (o que não está encerrado) de propósito: assim um
   * estado novo da plataforma é tratado como "em andamento" — conservador — em
   * vez de escapar de uma lista de estados ativos que envelheceria em silêncio.
   */
  public static Boolean haExecucaoEmAndamento() {
    return [
      SELECT COUNT()
      FROM AsyncApexJob
      WHERE
        JobType = 'BatchApex'
        AND ApexClass.Name = 'SOLCadenciaMotorBatch'
        AND Status NOT IN :ESTADOS_ENCERRADOS
    ] > 0;
  }

  /**
   * Cria o Scheduled Job. Recusa se já existir um com o mesmo nome — não
   * duplica (agendamento idempotente).
   *
   * @return o Id do CronTrigger criado.
   * @throws AgendamentoException se já houver um job com NOME_JOB.
   */
  public static Id agendar() {
    List<CronTrigger> existentes = [
      SELECT Id
      FROM CronTrigger
      WHERE CronJobDetail.Name = :NOME_JOB
    ];
    if (!existentes.isEmpty()) {
      throw new AgendamentoException(
        'Já existe um agendamento "' +
          NOME_JOB +
          '" (CronTrigger ' +
          existentes[0].Id +
          '). Não será duplicado.'
      );
    }
    return System.schedule(
      NOME_JOB,
      CRON_HORARIO,
      new SOLCadenciaMotorScheduler()
    );
  }

  /** Remove o Scheduled Job, se existir. Idempotente. */
  public static void desagendar() {
    for (CronTrigger ct : [
      SELECT Id
      FROM CronTrigger
      WHERE CronJobDetail.Name = :NOME_JOB
    ]) {
      System.abortJob(ct.Id);
    }
  }
}
