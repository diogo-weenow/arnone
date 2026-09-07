/**
 * CLICKUP-9439 / CLICKUP-9429 (absorvido) — agendador da varredura de durações
 * por etapa.
 *
 * Dispara `SOLDuracaoEtapaBatch` a cada hora, no minuto 45. Os minutos 0, 15 e
 * 30 já estão ocupados por CLICKUP-9394 (reprocessamento da distribuição),
 * CLICKUP-9398 (motor da cadência) e CLICKUP-9424 (prazo total). Os quatro
 * nunca disparam no mesmo instante.
 *
 * ==========================================================
 * POR QUE UM AGENDADOR NOVO, e não um mecanismo já existente
 * ==========================================================
 * A emenda do P.O. manda usar Batch e Scheduler dedicados SOMENTE se nenhum
 * mecanismo existente servir. Os três foram avaliados no código, e cada um
 * EXCLUI justamente os registros que a medição precisa alcançar:
 *
 *   - `SOLDistribuicaoReprocessamentoBatch` filtra `IsConverted = FALSE` e
 *     ainda depende do kill-switch da distribuição e de haver vendedor direto
 *     ativo. Leads convertidos — onde vivem as etapas 1 a 3 depois da conversão
 *     — ficam de fora;
 *   - `SOLPrazoTotalBatch` filtra `IsClosed = FALSE`, exatamente o oposto do
 *     que a etapa 6 precisa: só há duração de fechamento em Oportunidade
 *     FECHADA. Além disso o `execute()` dele LANÇA quando o lote tem erro, o
 *     que acoplaria falha analítica à reatribuição operacional de dono;
 *   - `SOLCadenciaMotorBatch` filtra `SOL_Contato_Efetivado__c = FALSE` e
 *     `SOL_Opt_Out__c = FALSE`, e devolve locator vazio em dia não útil.
 *     Justamente os Leads COM contato efetivado alimentam as etapas 2 e 3, e a
 *     pendência precisa ser varrida também em dia sem expediente.
 *
 * Absorver a varredura em qualquer um deles significaria alargar o escopo do
 * Batch de um card anterior e misturar falha analítica com falha operacional.
 * Por isso, agendador próprio — e no minuto 45, como a emenda determina.
 *
 * ===========================================================
 * POR QUE O SCHEDULER DISPARA OS DOIS ESCOPOS, e não o Batch
 * ===========================================================
 * A varredura de Oportunidades já foi encadeada no `finish()` do escopo de
 * Lead. Era inseguro: aquele mesmo `finish()` LANÇA quando encontra falha
 * técnica, e o `Database.executeBatch` do encadeamento estava na mesma
 * transação — a exceção pode desfazer o enfileiramento, e uma falha no escopo
 * de Lead silenciaria a varredura de Oportunidades sem deixar rastro.
 *
 * Agora os dois são disparados aqui, lado a lado e sem dependência. O que se
 * perde é a ordem dentro da mesma janela: a correção de um Lead pode levar uma
 * varredura a mais para descer à Oportunidade dele. É consistência eventual, e
 * é o que a política promete.
 *
 * O agendamento NÃO é criado automaticamente (sem inicializador estático, sem
 * trigger): use `SOLDuracaoEtapaScheduler.agendar()` de forma controlada (Apex
 * anônimo / Setup) — ver runbook de deploy.
 */
public without sharing class SOLDuracaoEtapaScheduler implements Schedulable {
  /** Nome único do Scheduled Job. */
  public static final String NOME_JOB = 'SOL Duracao - Varredura de duracao por etapa (hora em hora)';

  /** De hora em hora, no minuto 45. */
  public static final String CRON_HORARIO = '0 45 * * * ?';

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
    // SOBREPOSIÇÃO: se QUALQUER varredura anterior ainda não terminou, esta
    // janela inteira é PULADA. Duas passagens simultâneas não corromperiam nada
    // — a idempotência por etapa cuida disso —, mas disputariam os mesmos
    // registros sem entregar nada de novo. É também o que garante que nunca há
    // job duplicado do mesmo escopo. Mesma decisão de SOLCadenciaMotorScheduler.
    if (haExecucaoEmAndamento()) {
      System.debug(
        LoggingLevel.INFO,
        'SOLDuracaoEtapaScheduler: varredura anterior ainda em andamento; ' +
          'esta janela foi pulada.'
      );
      return;
    }
    // OS DOIS ESCOPOS SÃO DISPARADOS AQUI, INDEPENDENTES.
    //
    // Antes, o escopo de Oportunidade era encadeado no `finish()` do escopo de
    // Lead, e o mesmo `finish()` lançava quando havia falha — as duas coisas na
    // mesma transação. Uma falha no Lead podia, portanto, desfazer o
    // enfileiramento e silenciar a varredura de Oportunidades inteira. Aqui não
    // existe essa dependência: cada job vive por conta própria, e o que falha
    // marca apenas o `AsyncApexJob` dele.
    Database.executeBatch(
      new SOLDuracaoEtapaBatch(SOLDuracaoEtapaBatch.Escopo.LEAD),
      SOLDuracaoEtapaBatch.TAMANHO_LOTE
    );
    Database.executeBatch(
      new SOLDuracaoEtapaBatch(SOLDuracaoEtapaBatch.Escopo.OPORTUNIDADE),
      SOLDuracaoEtapaBatch.TAMANHO_LOTE
    );
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
        AND ApexClass.Name = 'SOLDuracaoEtapaBatch'
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
      new SOLDuracaoEtapaScheduler()
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
