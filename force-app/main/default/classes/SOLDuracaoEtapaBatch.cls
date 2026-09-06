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
 * ================
 * ENCADEAMENTO
 * ================
 * A varredura padrão começa pelos Leads e encadeia as Oportunidades no
 * `finish()`. A ordem importa: `recalcularLeads` propaga as etapas 1 a 3 para a
 * Oportunidade dos Leads já convertidos, então consertar o Lead primeiro faz a
 * Oportunidade já receber o valor certo na mesma rodada.
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

  /** Encadeia a varredura de Oportunidades ao terminar a de Leads. */
  @TestVisible
  private Boolean encadear;

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

  /** Varredura completa: Leads e, em seguida, Oportunidades. */
  public SOLDuracaoEtapaBatch() {
    this(Escopo.LEAD, false, true);
  }

  /** Varredura de um objeto só, sem encadear. */
  public SOLDuracaoEtapaBatch(Escopo alvo) {
    this(alvo, false, false);
  }

  /** Varredura de um objeto só, opcionalmente reprocessando inconsistências. */
  public SOLDuracaoEtapaBatch(Escopo alvo, Boolean incluirInconsistentes) {
    this(alvo, incluirInconsistentes, false);
  }

  private SOLDuracaoEtapaBatch(
    Escopo alvo,
    Boolean incluirInconsistentes,
    Boolean encadear
  ) {
    this.objetoAlvo = alvo == null ? Escopo.LEAD : alvo;
    this.incluirInconsistentes = incluirInconsistentes == true;
    this.encadear = encadear == true;
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

    if (this.encadear && !Test.isRunningTest()) {
      Database.executeBatch(
        new SOLDuracaoEtapaBatch(
          Escopo.OPORTUNIDADE,
          this.incluirInconsistentes
        ),
        TAMANHO_LOTE
      );
    } else if (this.encadear) {
      // Encadear em teste não executaria o segundo lote de verdade e ainda
      // consumiria uma posição de fila. Os testes disparam cada escopo
      // explicitamente, que é o que de fato prova o comportamento.
      System.debug(
        LoggingLevel.INFO,
        'SOLDuracaoEtapaBatch: encadeamento suprimido em contexto de teste.'
      );
    }

    // POR ÚLTIMO, e de propósito: uma varredura que encontrou falha técnica NÃO
    // pode terminar como sucesso. Lançar aqui, no `finish()`, marca o
    // AsyncApexJob e NÃO desfaz nada — os chunks já foram commitados em
    // transações próprias, então a medição correta dos outros registros
    // sobrevive. Lançar no `execute()` seria o contrário: derrubaria 199
    // registros bons por causa de um ruim, toda hora, para sempre.
    //
    // O encadeamento é disparado ANTES da checagem, senão uma falha no escopo
    // de Lead impediria a varredura das Oportunidades de acontecer.
    //
    // Este NÃO é o único sinal: as falhas que conseguiram ser gravadas viram
    // pendência `Falha técnica` no próprio registro e aparecem na lista
    // operacional. `falhasSemSinal` conta exatamente as que não couberam em
    // registro nenhum — e é por elas que este ponto existe.
    if (totalFalhas > 0) {
      throw new VarreduraComFalhaException(
        'SOLDuracaoEtapaBatch [' +
          objetoAlvo +
          '] terminou com falha técnica. ' +
          resumo()
      );
    }
    return;
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
