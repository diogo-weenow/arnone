/**
 * CLICKUP-9424 — Card 13: agendador da varredura do prazo total de 30 dias
 * úteis.
 *
 * Dispara SOLPrazoTotalBatch uma vez por dia. Nome de job ÚNICO e distinto do
 * job de reprocessamento da distribuição (CLICKUP-9394), em horário diferente:
 * os dois não interferem entre si. O agendamento NÃO é criado automaticamente
 * (sem inicializador estático, sem trigger): use
 * `SOLPrazoTotalScheduler.agendar()` de forma controlada (Apex anônimo /
 * Setup).
 */
public without sharing class SOLPrazoTotalScheduler implements Schedulable {
  /** Nome único do Scheduled Job. */
  public static final String NOME_JOB = 'SOL Prazo Total - Reatribuicao 30 dias uteis (diario)';

  /** Todo dia às 06:30 (o job de reprocessamento roda no minuto 0 de cada hora). */
  public static final String CRON_DIARIO = '0 30 6 * * ?';

  /** Tamanho de lote: pequeno, porque cada lote faz locks e DML aninhado. */
  public static final Integer TAMANHO_LOTE = 50;

  public class AgendamentoException extends Exception {
  }

  public void execute(SchedulableContext sc) {
    Database.executeBatch(new SOLPrazoTotalBatch(), TAMANHO_LOTE);
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
    return System.schedule(NOME_JOB, CRON_DIARIO, new SOLPrazoTotalScheduler());
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
