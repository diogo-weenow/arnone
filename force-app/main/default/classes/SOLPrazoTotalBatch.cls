/**
 * CLICKUP-9424 — Card 13: varredura do prazo total de 30 dias úteis.
 *
 * Seleciona as Oportunidades SOL (Recuperação Tributária ou ART 360) ABERTAS
 * cujo SOL_Prazo_Total_Comercial__c já venceu e que ainda não foram
 * reatribuídas por prazo, e delega a SOLPrazoTotalService — sem duplicar a
 * lógica de fila/roster/ponteiro.
 *
 * LOTE = 1 (SOLPrazoTotalScheduler.TAMANHO_LOTE): uma Oportunidade por
 * transação do Batch. Assim a falha de um registro (ex.: uma Task que não pode
 * ser transferida) fica isolada NA SUA transação — as demais Oportunidades
 * vencidas são varridas em transações próprias e reatribuídas normalmente.
 * Impacto de volume avaliado no PR: a varredura só enxerga Oportunidades já
 * vencidas e ainda não reatribuídas (SOL_Qtd_Reatribuicoes_Prazo__c nulo/≤0),
 * um conjunto pequeno e decrescente; o custo são algumas transações curtas por
 * hora.
 *
 * OBSERVABILIDADE DA FALHA (revisão do PR #15): quando o serviço devolve
 * r.comErro > 0, `execute()` LANÇA. A exceção não fica só em System.debug: o
 * AsyncApexJob do lote passa a registrar NumberOfErrors > 0 e ExtendedStatus
 * com o motivo — a falha é visível em Setup ▸ Apex Jobs e por SOQL. O lote 1
 * garante que só a Oportunidade problemática é revertida; ela volta ao filtro
 * na varredura seguinte.
 *
 * Salvaguardas:
 * - Kill-switch (`Ativo__c = false`) devolve QueryLocator vazio: nenhuma
 *   Oportunidade é tocada, de propósito.
 * - Singleton ausente ou fila inválida/ausente fazem `start()` LANÇAR, para o
 *   AsyncApexJob registrar a falha operacional (ver comentário de `start`).
 * - Roster vazio NÃO é barreira: as Oportunidades vencidas chegam ao serviço e
 *   recebem "Sem outro vendedor", sem troca de proprietário e sem virarem
 *   processadas.
 * - Ganho/Perdido nunca entram (IsClosed = true).
 * - Nunca recalcula o prazo: o filtro apenas LÊ SOL_Prazo_Total_Comercial__c.
 * - Oportunidades sem data de início / sem prazo calculado ficam de fora, sem
 *   inferência por CreatedDate.
 * - Executa em contexto de sistema; não depende de permission set.
 */
public without sharing class SOLPrazoTotalBatch implements Database.Batchable<SObject> {
  private Datetime limite;

  /** Lote com ao menos uma Oportunidade que falhou — evidencia no AsyncApexJob. */
  public class LoteComFalhaException extends Exception {
  }

  /** Configuração ausente/inválida — falha operacional, não sucesso silencioso. */
  public class ConfiguracaoInvalidaException extends Exception {
  }

  /**
   * Revisão final do PR #15 — as três situações de configuração são tratadas
   * SEPARADAMENTE, em vez de colapsadas num único "podeRodar":
   *
   * 1. **Kill-switch desligado** (`Ativo__c = false`): comportamento
   *    INTENCIONAL. QueryLocator vazio, nenhuma Oportunidade tocada, job
   *    termina como sucesso.
   * 2. **Roster vazio** (fila válida, mas sem vendedor direto ativo): NÃO é
   *    barreira. As Oportunidades vencidas CHEGAM ao serviço e recebem
   *    "Sem outro vendedor" — sem troca de proprietário e sem marcação como
   *    processadas, permitindo nova tentativa. Antes, `haVendedorDiretoAtivo()`
   *    devolvia QueryLocator vazio e essa situação ficava invisível.
   * 3. **Singleton ausente ou fila inválida/ausente**: falha OPERACIONAL. O
   *    `start()` LANÇA, e a plataforma marca o AsyncApexJob como falho com
   *    `ExtendedStatus` — nunca termina em silêncio como sucesso.
   */
  public Database.QueryLocator start(Database.BatchableContext bc) {
    SOL_Distribuicao_Estado__c estado = SOLDistribuicaoService.lerEstado();

    // (3) Singleton ausente: configuração quebrada, não "nada a fazer".
    if (estado == null) {
      throw new ConfiguracaoInvalidaException(
        'CLICKUP-9424 — registro de estado da distribuição SOL não encontrado. ' +
          'A varredura do prazo total não pode rodar sem o singleton.'
      );
    }

    // (1) Kill-switch desligado: encerra sem tocar em nada, de propósito.
    if (estado.Ativo__c != true) {
      return Database.getQueryLocator([SELECT Id FROM Opportunity WHERE Id = NULL]);
    }

    // (3) Fila ausente ou não habilitada para Lead: também falha operacional.
    // O roster VAZIO, ao contrário, é situação controlada e segue adiante.
    try {
      SOLDistribuicaoService.localizarFilaValida();
    } catch (SOLDistribuicaoService.DistribuicaoException e) {
      throw new ConfiguracaoInvalidaException(
        'CLICKUP-9424 — fila da distribuição SOL inválida ou ausente: ' + e.getMessage()
      );
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
    SOLPrazoTotalService.ResultadoPrazoTotal r = SOLPrazoTotalService.reatribuirPorPrazoTotal(ids);

    if (r.comErro > 0) {
      // Faz o AsyncApexJob registrar a falha (NumberOfErrors / ExtendedStatus).
      // Com lote = 1, reverte só a Oportunidade problemática desta transação; as
      // já reatribuídas em outras transações permanecem. A Opp revertida volta
      // ao filtro na próxima varredura.
      String detalhe = r.mensagens.isEmpty()
        ? SOLPrazoTotalService.MSG_ERRO_GENERICO
        : String.join(r.mensagens, ' | ');
      throw new LoteComFalhaException(
        'CLICKUP-9424 — ' +
          r.comErro +
          ' Oportunidade(s) não reatribuída(s) neste lote: ' +
          detalhe
      );
    }
  }

  public void finish(Database.BatchableContext bc) {
    AsyncApexJob job = [
      SELECT Status, JobItemsProcessed, TotalJobItems, NumberOfErrors, ExtendedStatus
      FROM AsyncApexJob
      WHERE Id = :bc.getJobId()
    ];
    System.debug(
      (job.NumberOfErrors > 0 ? LoggingLevel.ERROR : LoggingLevel.INFO),
      'SOLPrazoTotalBatch concluído: ' +
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
