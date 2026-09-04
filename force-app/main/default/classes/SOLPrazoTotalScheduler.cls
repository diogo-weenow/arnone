/**
 * CLICKUP-9424 — Card 13: agendador da varredura do prazo total de 30 dias
 * úteis.
 *
 * Dispara SOLPrazoTotalBatch a cada hora, no minuto 30. Nome de job ÚNICO e
 * distinto do job de reprocessamento da distribuição (CLICKUP-9394), que roda
 * no minuto 0 de cada hora: os dois nunca disparam no mesmo instante e não
 * interferem entre si.
 *
 * Por que de hora em hora, e não uma vez por dia (revisão do PR #15): o prazo
 * calculado por SOLBusinessHoursHelper vence na abertura do 30º dia útil —
 * normalmente 08:00 em São Paulo. Uma varredura diária às 06:30 só encontrava a
 * Oportunidade vencida no dia seguinte. No minuto 30 de cada hora, uma
 * Oportunidade que vence às 08:00 é reatribuída já na varredura das 08:30 do
 * mesmo dia.
 *
 * O agendamento NÃO é criado automaticamente (sem inicializador estático, sem
 * trigger): use `SOLPrazoTotalScheduler.agendar()` de forma controlada (Apex
 * anônimo / Setup).
 */
public without sharing class SOLPrazoTotalScheduler implements Schedulable {
  /** Nome único do Scheduled Job. */
  public static final String NOME_JOB = 'SOL Prazo Total - Reatribuicao 30 dias uteis (hora em hora)';

  /**
   * De hora em hora, no minuto 30. O job de reprocessamento da distribuição
   * (CLICKUP-9394) roda no minuto 0 — horários separados de propósito.
   */
  public static final String CRON_HORARIO = '0 30 * * * ?';

  /**
   * Tamanho de lote = 1: uma Oportunidade por transação do Batch. Revisão do
   * PR #15 — isola a atomicidade por Oportunidade, então a falha de um registro
   * (ex.: uma Task que não pode ser transferida) não desfaz as reatribuições
   * das outras Oportunidades do mesmo disparo. Impacto de volume avaliado e
   * documentado no PR: a varredura processa apenas Oportunidades já vencidas e
   * ainda não reatribuídas (SOL_Qtd_Reatribuicoes_Prazo__c nulo/≤0), um conjunto
   * pequeno e decrescente; o custo extra são algumas transações curtas por hora.
   */
  public static final Integer TAMANHO_LOTE = 1;

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
    return System.schedule(NOME_JOB, CRON_HORARIO, new SOLPrazoTotalScheduler());
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
