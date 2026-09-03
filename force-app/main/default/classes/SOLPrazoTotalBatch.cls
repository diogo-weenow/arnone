/**
 * CLICKUP-9424 — Card 13: varredura do prazo total de 30 dias úteis.
 *
 * Seleciona as Oportunidades SOL (Recuperação Tributária ou ART 360) ABERTAS
 * cujo SOL_Prazo_Total_Comercial__c já venceu e que ainda não foram
 * reatribuídas por prazo, e delega a SOLPrazoTotalService — sem duplicar a
 * lógica de fila/roster/ponteiro.
 *
 * Salvaguardas:
 * - Só age se o singleton estiver ATIVO (kill-switch) e houver ao menos um
 *   vendedor direto ativo na fila; caso contrário `start()` devolve um
 *   QueryLocator vazio e nenhuma Oportunidade é tocada.
 * - Ganho/Perdido nunca entram (IsClosed = true).
 * - Nunca recalcula o prazo: o filtro apenas LÊ SOL_Prazo_Total_Comercial__c.
 * - Oportunidades sem data de início / sem prazo calculado ficam de fora, sem
 *   inferência por CreatedDate.
 * - Uma falha em um lote não compromete os lotes já concluídos; o serviço tem
 *   Savepoint/rollback próprio e a varredura é idempotente
 *   (SOL_Qtd_Reatribuicoes_Prazo__c > 0 marca como processada).
 * - Executa em contexto de sistema; não depende de permission set.
 */
public without sharing class SOLPrazoTotalBatch implements Database.Batchable<SObject> {
  private Datetime limite;

  public Database.QueryLocator start(Database.BatchableContext bc) {
    SOL_Distribuicao_Estado__c estado = SOLDistribuicaoService.lerEstado();

    Boolean podeRodar =
      estado != null &&
      estado.Ativo__c == true &&
      SOLDistribuicaoService.haVendedorDiretoAtivo();

    if (!podeRodar) {
      return Database.getQueryLocator([SELECT Id FROM Opportunity WHERE Id = NULL]);
    }

    this.limite = System.now();
    return Database.getQueryLocator(
      [
        SELECT Id
        FROM Opportunity
        WHERE
          RecordType.DeveloperName = 'SOL'
          AND SOL_Produto_Negocio__c IN ('Recuperação Tributária', 'ART 360')
          AND IsClosed = FALSE
          AND SOL_Data_Inicio_Ciclo_Comercial__c != NULL
          AND SOL_Prazo_Total_Comercial__c != NULL
          AND SOL_Prazo_Total_Comercial__c <= :limite
          AND (SOL_Qtd_Reatribuicoes_Prazo__c = NULL
          OR SOL_Qtd_Reatribuicoes_Prazo__c <= 0)
      ]
    );
  }

  public void execute(Database.BatchableContext bc, List<Opportunity> escopo) {
    // Sem SOQL/DML no laço: extrai os Ids e delega ao serviço uma única vez.
    List<Id> ids = new List<Id>(new Map<Id, Opportunity>(escopo).keySet());
    SOLPrazoTotalService.reatribuirPorPrazoTotal(ids);
  }

  public void finish(Database.BatchableContext bc) {
    System.debug(LoggingLevel.INFO, 'SOLPrazoTotalBatch concluído: ' + bc.getJobId());
  }
}
