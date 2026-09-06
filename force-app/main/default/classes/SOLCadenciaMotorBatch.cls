/**
 * CLICKUP-9398 — varredura que alimenta o motor da cadência de contato SOL.
 *
 * Seleciona os Leads da Arnone Soluções com CICLO DE CONTATO ABERTO e delega a
 * `SOLCadenciaMotorService` — sem duplicar cálculo de dia útil, criação de
 * tarefa, idempotência ou reatribuição. O `execute` não tem regra: extrai os
 * Ids e chama o serviço uma única vez por lote.
 *
 * O ESCOPO é deliberadamente largo — todo Lead com ciclo aberto, e não só os do
 * dia de hoje. Quem sabe em que dia cada Lead está é o motor, que precisa ver o
 * conjunto inteiro para também identificar os ESGOTADOS e entregá-los à
 * reatribuição (CLICKUP-9400). Filtrar por dia aqui exigiria replicar o
 * calendário no SOQL, que é justamente o que não se quer.
 *
 * Salvaguardas, no mesmo padrão do CLICKUP-9424:
 * - Kill-switch (`Ativo__c = false`) devolve QueryLocator vazio: nenhum Lead é
 *   tocado, de propósito, e o job termina como sucesso.
 * - Singleton ausente faz `start()` LANÇAR — configuração quebrada não é "nada
 *   a fazer", e o AsyncApexJob precisa registrar isso.
 * - Calendário comercial ausente/inativo também LANÇA, sem fallback: sem ele
 *   não há dia útil a calcular e qualquer suposição criaria tarefa no dia
 *   errado, em silêncio.
 * - DIA NÃO ÚTIL (fim de semana, feriado) devolve QueryLocator vazio: a
 *   varredura roda de hora em hora, inclusive no sábado, e simplesmente não faz
 *   nada nesses dias.
 * - `r.comErro > 0` faz o `execute` LANÇAR, para o AsyncApexJob registrar
 *   NumberOfErrors/ExtendedStatus. A transação inteira do lote é revertida e os
 *   Leads voltam ao escopo na varredura seguinte — a criação é idempotente, um
 *   retry não duplica nada.
 * - Nunca toca Lead convertido, de outra BU, sem ciclo, com contato efetivado,
 *   opt-out ou negócio perdido.
 * - Executa em contexto de sistema; não depende de permission set.
 */
public without sharing class SOLCadenciaMotorBatch implements Database.Batchable<SObject> {
  /** Lote com ao menos um Lead que falhou — evidencia no AsyncApexJob. */
  public class LoteComFalhaException extends Exception {
  }

  public Database.QueryLocator start(Database.BatchableContext bc) {
    SOL_Distribuicao_Estado__c estado = SOLDistribuicaoService.lerEstado();

    // Configuração quebrada: falha OPERACIONAL, nunca sucesso silencioso.
    if (estado == null) {
      throw new SOLCadenciaMotorService.ConfiguracaoInvalidaException(
        'CLICKUP-9398 — registro de estado da distribuição SOL não encontrado. ' +
          'A varredura da cadência não pode rodar sem o singleton.'
      );
    }

    // Kill-switch desligado: encerra sem tocar em nada, de propósito.
    if (estado.Ativo__c != true) {
      return Database.getQueryLocator([SELECT Id FROM Lead WHERE Id = NULL]);
    }

    // Calendário: pré-requisito duro, sem fallback.
    Id bhId = SOLBusinessHoursHelper.businessHoursId();
    if (bhId == null) {
      throw new SOLBusinessHoursHelper.CalendarioIndisponivelException(
        'CLICKUP-9398 — calendário comercial da Arnone Soluções ausente ou inativo. ' +
          'A varredura da cadência não pode calcular o dia útil.'
      );
    }

    // Dia sem expediente: nada a fazer hoje.
    if (
      !SOLBusinessHoursHelper.ehDiaUtil(
        bhId,
        SOLCadenciaMotorService.dataDeReferencia()
      )
    ) {
      return Database.getQueryLocator([SELECT Id FROM Lead WHERE Id = NULL]);
    }

    return Database.getQueryLocator(
      [
        SELECT Id
        FROM Lead
        WHERE
          RecordType.DeveloperName = 'SOL'
          AND IsConverted = FALSE
          AND SOL_Data_Inicio_Ciclo_Contato__c != NULL
          AND SOL_Contato_Efetivado__c = FALSE
          AND SOL_Opt_Out__c = FALSE
      ]
    );
  }

  public void execute(Database.BatchableContext bc, List<Lead> escopo) {
    // Sem SOQL/DML no laço: extrai os Ids e delega ao serviço uma única vez.
    List<Id> ids = new List<Id>(new Map<Id, Lead>(escopo).keySet());
    SOLCadenciaMotorService.ResultadoMotor r = SOLCadenciaMotorService.executar(
      ids
    );

    if (r.comErro > 0) {
      String detalhe = r.mensagens.isEmpty()
        ? 'Falha controlada sem mensagem.'
        : String.join(r.mensagens, ' | ');
      throw new LoteComFalhaException(
        'CLICKUP-9398 — ' +
          r.comErro +
          ' Lead(s) não atendido(s) neste lote: ' +
          detalhe
      );
    }
  }

  public void finish(Database.BatchableContext bc) {
    AsyncApexJob job = [
      SELECT
        Status,
        JobItemsProcessed,
        TotalJobItems,
        NumberOfErrors,
        ExtendedStatus
      FROM AsyncApexJob
      WHERE Id = :bc.getJobId()
    ];
    System.debug(
      (job.NumberOfErrors > 0 ? LoggingLevel.ERROR : LoggingLevel.INFO),
      'SOLCadenciaMotorBatch concluído: ' +
        bc.getJobId() +
        ' status=' +
        job.Status +
        ' itens=' +
        job.JobItemsProcessed +
        '/' +
        job.TotalJobItems +
        ' erros=' +
        job.NumberOfErrors +
        ' detalhe=' +
        job.ExtendedStatus
    );
  }
}
