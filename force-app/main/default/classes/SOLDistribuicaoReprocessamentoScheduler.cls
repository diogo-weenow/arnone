/**
 * CLICKUP-9394 — ETAPA 6: agendador da varredura de reprocessamento SOL.
 *
 * Dispara SOLDistribuicaoReprocessamentoBatch uma vez por hora. O agendamento
 * NÃO é criado automaticamente (sem inicializador estático, sem trigger): use
 * `SOLDistribuicaoReprocessamentoScheduler.agendar()` de forma controlada
 * (Apex anônimo / Setup) — ver runbook.
 */
public without sharing class SOLDistribuicaoReprocessamentoScheduler implements Schedulable {
  /** Nome único do Scheduled Job. */
  public static final String NOME_JOB = 'SOL Distribuicao - Reprocessamento (hora em hora)';

  /** Todo dia, no minuto 0 de cada hora. */
  public static final String CRON_HORARIO = '0 0 * * * ?';

  /** Tamanho de lote da varredura. */
  public static final Integer TAMANHO_LOTE = 200;

  public class AgendamentoException extends Exception {
  }

  public void execute(SchedulableContext sc) {
    Database.executeBatch(
      new SOLDistribuicaoReprocessamentoBatch(),
      TAMANHO_LOTE
    );
  }

  /**
   * Cria o Scheduled Job. Recusa se já existir um com o mesmo nome — não
   * duplica.
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
      new SOLDistribuicaoReprocessamentoScheduler()
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