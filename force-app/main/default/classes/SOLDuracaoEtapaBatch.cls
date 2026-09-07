/**
 * CLICKUP-9439 / CLICKUP-9429 (absorvido) — varredura das durações por etapa.
 *
 * Faz DUAS coisas com a mesma classe, e as duas de forma idempotente:
 *
 *   1. BACKFILL — registros cujos DOIS marcos de alguma etapa já existem e cuja
 *      duração está vazia. Não estima data, não preenche lacuna com zero e não
 *      inventa marco: registro sem marco comprovável é simplesmente ignorado.
 *   2. VARREDURA DE PENDÊNCIAS TRANSITÓRIAS — registros marcados com
 *      `SOL_Duracao_Pendente__c = true` e motivo "Calendário indisponível",
 *      que voltam a ser calculáveis assim que o Business Hours é reativado.
 *
 * ===================================================================
 * POR QUE A PENDÊNCIA INCONSISTENTE NÃO ENTRA NA VARREDURA AUTOMÁTICA
 * ===================================================================
 * Falha de calendário é TRANSITÓRIA: reprocessar resolve. Destino anterior à
 * origem é DADO INVÁLIDO: reprocessar produz exatamente a mesma recusa, para
 * sempre. Incluí-la seria retry perpétuo — o que a decisão do P.O. proíbe
 * nominalmente. Por isso a query recusa o motivo "Intervalo inconsistente".
 *
 * CONSEQUÊNCIA ASSUMIDA, e o caminho para ela: um registro já marcado como
 * inconsistente que conclua OUTRA etapa depois não é alcançado por esta
 * varredura. Ele é alcançado pelo Flow daquela etapa, que roda na hora e
 * reavalia o registro inteiro. Só sobra o caso do registro histórico que nunca
 * mais é tocado — e para ele existe o construtor com `incluirInconsistentes`,
 * executado sob demanda pelo administrador DEPOIS de corrigir as datas. É
 * decisão humana, não laço automático.
 *
 * =========================
 * ESCOPOS INDEPENDENTES
 * =========================
 * Cada escopo é uma execução própria, disparada por `SOLDuracaoEtapaScheduler`.
 * NÃO há encadeamento no `finish()`: enfileirar o segundo escopo na mesma
 * transação em que se lança a exceção de falha significaria apostar que o
 * rollback não desfaz o enfileiramento — e uma falha no escopo de Lead poderia
 * silenciar a varredura de Oportunidades. Independentes, uma falha marca só o
 * job dela.
 *
 * NÃO LANÇA em `execute()`, ao contrário de `SOLPrazoTotalBatch`: lá a falha é
 * operacional e precisa marcar o job como falho; aqui é analítica, e derrubar o
 * lote inteiro por um registro apagaria a medição correta dos outros 199.
 * `SOLDuracaoEtapaService` já devolve as contagens, que são somadas no estado e
 * registradas no `finish()`.
 */
public without sharing class SOLDuracaoEtapaBatch implements Database.Batchable<SObject>, Database.Stateful {
  /** Tamanho de lote padrão da varredura. */
  public static final Integer TAMANHO_LOTE = 200;

  /** Objeto varrido nesta execução. */
  public enum Escopo {
    LEAD,
    OPORTUNIDADE
  }

  /**
   * Chama-se `objetoAlvo`, e não `escopo`: Apex ignora maiúsculas e minúsculas
   * nos identificadores, então um campo `escopo` colidiria com o enum `Escopo`
   * e o compilador recusaria `Escopo.LEAD` dentro de método de instância.
   */
  @TestVisible
  private Escopo objetoAlvo;

  /** Inclui as pendências por intervalo inconsistente. Só sob demanda. */
  @TestVisible
  private Boolean incluirInconsistentes;

  /** Motivos de pendência que esta execução aceita reprocessar. */
  @TestVisible
  private Set<String> motivosElegiveis;

  // Estado acumulado entre os chunks (Database.Stateful).
  @TestVisible
  private Integer totalAvaliados = 0;
  @TestVisible
  private Integer totalCalculadas = 0;
  @TestVisible
  private Integer totalPendentes = 0;
  @TestVisible
  private Integer totalJaPreenchidas = 0;
  @TestVisible
  private Integer totalIgnoradas = 0;
  @TestVisible
  private Integer totalMarcos = 0;
  @TestVisible
  private Integer totalAtualizados = 0;
  @TestVisible
  private Integer totalOportunidadesSincronizadas = 0;
  @TestVisible
  private Integer totalFalhas = 0;
  @TestVisible
  private Integer totalFalhasSinalizadas = 0;
  @TestVisible
  private Integer totalFalhasSemSinal = 0;

  /** Varredura do escopo de Lead. Cada escopo é disparado por conta própria. */
  public SOLDuracaoEtapaBatch() {
    this(Escopo.LEAD, false);
  }

  /** Varredura de um escopo. */
  public SOLDuracaoEtapaBatch(Escopo alvo) {
    this(alvo, false);
  }

  /** Varredura de um escopo, opcionalmente reprocessando inconsistências. */
  public SOLDuracaoEtapaBatch(Escopo alvo, Boolean incluirInconsistentes) {
    this.objetoAlvo = alvo == null ? Escopo.LEAD : alvo;
    this.incluirInconsistentes = incluirInconsistentes == true;
    this.motivosElegiveis = new Set<String>(
      SOLDuracaoEtapaService.MOTIVOS_REPROCESSAVEIS
    );
    if (this.incluirInconsistentes) {
      this.motivosElegiveis.add(SOLDuracaoEtapaService.MOTIVO_INCONSISTENTE);
    }
  }

  /**
   * O filtro tem duas metades ligadas por AND, e cada uma responde a uma
   * pergunta diferente:
   *
   *   - a primeira decide QUAIS PENDÊNCIAS são elegíveis (nenhuma, ou a
   *     transitória, ou também a inconsistente sob demanda);
   *   - a segunda decide O QUE HÁ PARA FAZER (pendência aberta, ou alguma etapa
   *     com os dois marcos e a duração vazia).
   *
   * Rodar duas vezes seguidas produz o mesmo resultado: na segunda passagem os
   * registros da primeira já têm duração e não casam mais com nenhuma cláusula.
   */
  public Database.QueryLocator start(Database.BatchableContext bc) {
    Set<String> motivos = this.motivosElegiveis;
    if (this.objetoAlvo == Escopo.OPORTUNIDADE) {
      return Database.getQueryLocator(
        [
          SELECT Id
          FROM Opportunity
          WHERE
            RecordType.DeveloperName = 'SOL'
            AND (SOL_Duracao_Pendencia_Motivo__c = NULL
            OR SOL_Duracao_Pendencia_Motivo__c IN :motivos)
            AND (SOL_Duracao_Pendente__c = TRUE
            OR (SOL_Data_Distribuicao__c != NULL
            AND SOL_Data_Primeira_Ligacao__c != NULL
            AND SOL_Dias_Primeira_Ligacao__c = NULL)
            OR (SOL_Data_Primeira_Ligacao__c != NULL
            AND SOL_Data_Inicio_Ciclo_Comercial__c != NULL
            AND SOL_Dias_Contato_Efetivado__c = NULL)
            OR (SOL_Data_Inicio_Ciclo_Comercial__c != NULL
            AND SOL_Data_Reuniao_Procuracao__c != NULL
            AND SOL_Dias_Reuniao_Procuracao__c = NULL)
            OR (SOL_Data_Solicitacao_Calculo__c != NULL
            AND SOL_Data_Recebimento_Calculo__c != NULL
            AND SOL_Dias_Calculo_Juridico__c = NULL)
            OR (SOL_Data_Recebimento_Calculo__c != NULL
            AND SOL_Data_Reuniao_Final__c != NULL
            AND SOL_Dias_Reuniao_Final__c = NULL)
            OR (SOL_Data_Reuniao_Final__c != NULL
            AND SOL_Data_Encerramento__c != NULL
            AND SOL_Dias_Fechamento__c = NULL))
        ]
      );
    }
    return Database.getQueryLocator(
      [
        SELECT Id
        FROM Lead
        WHERE
          RecordType.DeveloperName = 'SOL'
          AND (SOL_Duracao_Pendencia_Motivo__c = NULL
          OR SOL_Duracao_Pendencia_Motivo__c IN :motivos)
          AND (SOL_Duracao_Pendente__c = TRUE
          OR (SOL_Data_Distribuicao__c != NULL
          AND SOL_Data_Primeira_Ligacao__c != NULL
          AND SOL_Dias_Primeira_Ligacao__c = NULL)
          OR (SOL_Data_Primeira_Ligacao__c != NULL
          AND SOL_Data_Contato_Efetivado__c != NULL
          AND SOL_Dias_Contato_Efetivado__c = NULL)
          OR (SOL_Data_Contato_Efetivado__c != NULL
          AND SOL_Data_Reuniao_Procuracao__c != NULL
          AND SOL_Dias_Reuniao_Procuracao__c = NULL)
          OR (SOL_Data_Reuniao_Realizada__c != NULL
          AND SOL_Data_Recebimento_Procuracao__c != NULL
          AND SOL_Data_Reuniao_Procuracao__c = NULL))
      ]
    );
  }

  public void execute(Database.BatchableContext bc, List<SObject> lote) {
    // Sem SOQL/DML no laço: extrai os Ids e delega ao serviço uma única vez.
    List<Id> ids = new List<Id>(new Map<Id, SObject>(lote).keySet());
    SOLDuracaoEtapaService.ResultadoDuracao r = this.objetoAlvo ==
      Escopo.OPORTUNIDADE
      ? SOLDuracaoEtapaService.recalcularOportunidades(ids)
      : SOLDuracaoEtapaService.recalcularLeads(ids);
    acumular(r);
  }

  /** Varredura que terminou com falha técnica em algum registro. */
  public class VarreduraComFalhaException extends Exception {
  }

  public void finish(Database.BatchableContext bc) {
    System.debug(
      LoggingLevel.INFO,
      'SOLDuracaoEtapaBatch [' + objetoAlvo + '] ' + resumo()
    );

    // NÃO HÁ ENCADEAMENTO AQUI, e a ausência é o ponto.
    //
    // A versão anterior enfileirava o escopo de Oportunidade neste mesmo método
    // e DEPOIS lançava quando havia falha, apoiada na ideia de que "enfileirar
    // antes de lançar preserva a segunda varredura". Isso nunca foi comprovado
    // e é inseguro: o `Database.executeBatch` e o `throw` estão na MESMA
    // transação, e a exceção pode desfazer o enfileiramento. O resultado seria o
    // pior possível — uma falha no escopo de Lead silenciando a varredura de
    // Oportunidades sem que ninguém percebesse.
    //
    // Quem dispara os dois escopos agora é `SOLDuracaoEtapaScheduler`, de forma
    // INDEPENDENTE. Nenhum depende do sucesso do outro, e o preço é abrir mão da
    // ordem Lead -> Oportunidade dentro da mesma janela: a propagação da
    // correção de um Lead para a Oportunidade dele pode levar uma varredura a
    // mais. É consistência eventual, que é exatamente o que a política promete.
    if (totalFalhas > 0) {
      throw new VarreduraComFalhaException(
        'SOLDuracaoEtapaBatch [' +
          objetoAlvo +
          '] terminou com falha técnica. ' +
          resumo()
      );
    }
  }

  private void acumular(SOLDuracaoEtapaService.ResultadoDuracao r) {
    if (r == null) {
      return;
    }
    totalAvaliados += r.avaliados;
    totalCalculadas += r.calculadas;
    totalPendentes += r.pendentes;
    totalJaPreenchidas += r.jaPreenchidas;
    totalIgnoradas += r.ignoradas;
    totalMarcos += r.marcosConsolidados;
    totalAtualizados += r.registrosAtualizados;
    totalOportunidadesSincronizadas += r.oportunidadesSincronizadas;
    totalFalhas += r.falhas;
    totalFalhasSinalizadas += r.falhasSinalizadas;
    totalFalhasSemSinal += r.falhasSemSinal;
  }

  /** Texto do resumo acumulado, usado no log e pelos testes. */
  @TestVisible
  private String resumo() {
    return 'avaliados=' +
      totalAvaliados +
      ' calculadas=' +
      totalCalculadas +
      ' pendentes=' +
      totalPendentes +
      ' jaPreenchidas=' +
      totalJaPreenchidas +
      ' ignoradas=' +
      totalIgnoradas +
      ' marcosConsolidados=' +
      totalMarcos +
      ' registrosAtualizados=' +
      totalAtualizados +
      ' oportunidadesSincronizadas=' +
      totalOportunidadesSincronizadas +
      ' falhas=' +
      totalFalhas +
      ' falhasSinalizadas=' +
      totalFalhasSinalizadas +
      ' falhasSemSinal=' +
      totalFalhasSemSinal;
  }
}
