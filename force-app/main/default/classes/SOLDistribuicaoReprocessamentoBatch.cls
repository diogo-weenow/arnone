/**
 * CLICKUP-9394 — ETAPA 6: reprocessamento seguro da distribuição SOL.
 *
 * Varre periodicamente os Leads do Record Type SOL que ficaram sem
 * distribuição efetiva (Erro / Fallback / Pendente / vazio) e os reenvia para
 * SOLDistribuicaoService.distribuir(). Não duplica a lógica do serviço.
 *
 * Salvaguardas:
 * - Só age dentro da vigência (Inicio_Vigencia__c). Leads criados antes ficam
 *   de fora — status vazio antigo NÃO é reprocessado.
 * - Só age se o singleton estiver ATIVO, a fila for válida e houver ao menos um
 *   vendedor direto ativo. Caso contrário `start()` devolve um QueryLocator
 *   vazio: nenhum Lead é tocado (sem churn repetido).
 * - Nunca toca Leads convertidos, de outra BU ou já Distribuido.
 * - Uma falha em um lote não compromete os lotes já concluídos (cada execute é
 *   uma transação; o serviço ainda tem Savepoint/rollback próprio).
 * - Executa em contexto de sistema; não depende de Assignment Rule nem de
 *   permission set.
 */
public without sharing class SOLDistribuicaoReprocessamentoBatch implements Database.Batchable<SObject> {
  private Datetime inicioVigencia;

  public Database.QueryLocator start(Database.BatchableContext bc) {
    SOL_Distribuicao_Estado__c estado = SOLDistribuicaoService.lerEstado();

    Boolean podeReprocessar =
      estado != null &&
      estado.Ativo__c == true &&
      estado.Inicio_Vigencia__c != null &&
      SOLDistribuicaoService.haVendedorDiretoAtivo();

    if (!podeReprocessar) {
      // Encerra sem tocar em nenhum Lead.
      return Database.getQueryLocator(
        [SELECT Id FROM Lead WHERE Id = NULL]
      );
    }

    this.inicioVigencia = estado.Inicio_Vigencia__c;
    return Database.getQueryLocator(
      [
        SELECT Id
        FROM Lead
        WHERE
          RecordType.DeveloperName = 'SOL'
          AND IsConverted = FALSE
          AND CreatedDate >= :inicioVigencia
          AND (SOL_Status_Distribuicao__c IN ('Erro', 'Fallback', 'Pendente')
          OR SOL_Status_Distribuicao__c = NULL)
      ]
    );
  }

  public void execute(Database.BatchableContext bc, List<Lead> escopo) {
    // Sem SOQL/DML no laço: extrai os Ids e delega ao serviço uma única vez.
    List<Id> ids = new List<Id>(new Map<Id, Lead>(escopo).keySet());
    SOLDistribuicaoService.distribuir(ids);
  }

  public void finish(Database.BatchableContext bc) {
    // Sem notificações nesta etapa.
    System.debug(
      LoggingLevel.INFO,
      'SOLDistribuicaoReprocessamentoBatch concluído: ' + bc.getJobId()
    );
  }
}