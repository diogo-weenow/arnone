/**
 * CLICKUP-9425 — Card 14 — Encerramento automático de tarefas ao perder o
 * negócio da Arnone Soluções.
 *
 * Quando um negócio da BU é perdido, TODAS as Tasks abertas vinculadas são
 * encerradas, em qualquer etapa da jornada. Vale para os DOIS produtos:
 * "Recuperação Tributária" e "ART 360".
 *
 * DUAS ENTRADAS SEPARADAS, uma por objeto — cada uma com sua automação:
 *
 *   encerrarPorLeadPerdido(leadIds)          ← Flow SOL_Encerrar_Tarefas_Lead_Perdido
 *     Perda ANTES da conversão. O sinal é EXATO e composto: Record Type SOL +
 *     Status "Desqualificado" + SOL_Motivo_Desqualificacao__c "Negócio perdido"
 *     + SOL_Opt_Out__c = false. Tasks pelo WhoId.
 *     NÃO é "todo Desqualificado é perda": o opt-out (CLICKUP-9418) desqualifica
 *     com motivo "Opt-out" e SOL_Opt_Out__c = true, então NUNCA entra aqui — os
 *     dois fluxos ficam isolados e nenhum sobrescreve o dado do outro.
 *
 *   encerrarPorOportunidadePerdida(oppIds, etapasAnteriores)
 *                                            ← Flow SOL_Encerrar_Tarefas_Oportunidade_Perdida
 *     Perda DEPOIS da conversão: StageName = "Perdido". Tasks pelo WhatId.
 *     (CLICKUP-9438) O segundo argumento traz, por Oportunidade, a etapa REAL
 *     de onde ela saiu — `$Record__Prior.StageName` no Flow after-save. É
 *     OBRIGATÓRIO: depois do save esse valor não existe mais em lugar nenhum
 *     consultável, e sem ele o relatório de perdas registraria "Perdido" como
 *     etapa anterior, isto é, o destino no lugar da origem. Oportunidade no
 *     escopo sem etapa anterior utilizável ABORTA a perda com mensagem
 *     controlada — não existe overload de um argumento só, de propósito:
 *     ele seria uma porta para perder negócio sem registrar a ocorrência.
 *
 * O QUE É GRAVADO em cada Task cancelada, na MESMA atualização:
 *   Status = "Cancelada"
 *   SOL_Motivo_Cancelamento__c = "Negócio perdido"
 *   SOL_Cancelada_Por_Perda__c = true
 * É esse trio que torna o cancelamento por perda DISTINGUÍVEL de uma tarefa
 * executada (Completed) e de um cancelamento por outro motivo, e é o par
 * (checkbox + motivo) que autoriza a VR SOL_Cancelada_Exige_Classificacao a
 * aceitar tarefa MANUAL sem SOL_Tipo_Tarefa__c.
 *
 * ALCANCE DA BUSCA: TODAS as Tasks abertas (IsClosed = false) do pai, sem
 * filtrar por SOL_Tipo_Tarefa__c — inclusive as MANUAIS, criadas pelo vendedor,
 * que legitimamente não têm tipo técnico. Nenhum tipo é inventado para elas e o
 * Subject NUNCA é usado como classificador. Tasks concluídas ou já canceladas
 * (IsClosed = true) ficam INTACTAS — nada é apagado.
 *
 * PRECEDÊNCIA SOBRE O CLICKUP-9423: em "Ganho", quem age é o 9423 — a Task
 * "Fechamento" vira Completed com SOL_Encerrado_Pela_Oportunidade__c = true. Em
 * "Perdido", o 9423 não age mais (SOLFechamentoService.ETAPAS_ENCERRAMENTO ficou
 * só com "Ganho") e é este serviço que a deixa Cancelada, com motivo e flag de
 * perda. Sem sobreposição e sem mudar o comportamento de Ganho.
 *
 * IDEMPOTÊNCIA: só Tasks abertas entram, e cancelar fecha a Task
 * (TaskStatus "Cancelada" tem IsClosed = true). Uma segunda execução — replay do
 * Flow, reprocessamento, concorrência — não encontra nada para cancelar e não
 * altera o que já foi gravado.
 *
 * ATOMICIDADE: Savepoint no início; se o cancelamento falhar, o rollback desfaz
 * o que este serviço tocou e o método RELANÇA NegocioPerdidoException. O
 * Invocable propaga ao Flow com flowTransactionModel = CurrentTransaction, o que
 * aborta a PRÓPRIA PERDA (a desqualificação do Lead ou a mudança da Oportunidade
 * para "Perdido") com mensagem controlada. Não existe negócio perdido com
 * tarefas abertas sobrando.
 *
 * BLOQUEIO DAS AUTOMAÇÕES POSTERIORES: os predicados públicos `leadPerdido` e
 * `oportunidadePerdida` são a régua ÚNICA de "este negócio já foi perdido",
 * consumida pelos serviços dos cards 9401–9424 (procuração, reunião comercial,
 * solicitação de cálculo, acompanhamento, reunião final, fechamento,
 * distribuição, reatribuição por falta de contato, contato efetivado, opt-out e
 * prazo total). São funções PURAS: não fazem SOQL nem DML, recebem o registro
 * que o serviço chamador já carregou — normalmente com FOR UPDATE — de modo que
 * a validação usa o estado ATUAL do banco, sem consulta extra e sem duplicar a
 * regra.
 *
 * Bulk-safe: nenhuma consulta/DML em laço. FOR UPDATE nos pais e nas Tasks.
 * NÃO cria tarefas, NÃO reatribui, NÃO mexe em etapa/motivo do pai, NÃO apaga
 * registros e NÃO altera os dois schedulers existentes.
 */
public without sharing class SOLNegocioPerdidoService {
  // ------------------------------------------------------------- vocabulário
  /** Record Type da BU. */
  @TestVisible
  private static final String RECORD_TYPE_SOL = 'SOL';

  /** Os DOIS produtos no escopo do card. */
  public static final Set<String> PRODUTOS_NO_ESCOPO = new Set<String>{
    'Recuperação Tributária',
    'ART 360'
  };

  /** Status de perda do Lead (não existe "Perdido" em LeadStatus). */
  public static final String LEAD_STATUS_DESQUALIFICADO = 'Desqualificado';
  /** Motivo EXATO que caracteriza perda do negócio no Lead. */
  public static final String MOTIVO_DESQUALIFICACAO_PERDA = 'Negócio perdido';
  /** Etapa de perda da Oportunidade. */
  public static final String ETAPA_PERDIDO = 'Perdido';
  /** Motivo gravado na Task cancelada por perda. */
  public static final String MOTIVO_CANCELAMENTO_PERDA = 'Negócio perdido';
  /** Status de cancelamento da Task (IsClosed = true). */
  public static final String TASK_STATUS_CANCELADA = 'Cancelada';

  /** Falha ao encerrar as tarefas de um Lead perdido (a perda é abortada). */
  public static final String MSG_FALHA_LEAD = 'Não foi possível encerrar as tarefas abertas do lead perdido. A desqualificação foi cancelada — tente novamente.';
  /** Falha ao encerrar as tarefas de uma Oportunidade perdida (a perda é abortada). */
  public static final String MSG_FALHA_OPORTUNIDADE = 'Não foi possível encerrar as tarefas abertas da Oportunidade perdida. A mudança para "Perdido" foi cancelada — tente novamente.';

  /**
   * (CLICKUP-9438) Perda chegou ao serviço sem a etapa de onde a Oportunidade
   * saiu. Aborta em vez de gravar a ocorrência com etapa vazia ou com
   * "Perdido" — que é o destino, não a origem.
   */
  public static final String MSG_ETAPA_ANTERIOR_AUSENTE = 'Não foi possível registrar a perda desta Oportunidade: a automação não informou a etapa anterior à perda. A mudança para "Perdido" foi cancelada — tente novamente.';

  /**
   * (CLICKUP-9438) A Oportunidade chegou como perdida sem o contador de
   * transições (`SOL_Qtd_Perdas__c`) que o Flow before-save
   * SOL_Marco_Perda_Oportunidade carimba no próprio save. Sem ele não há como
   * distinguir reprocessamento de nova perda após reabertura — e as duas
   * respostas erradas custam caro: ou some uma ocorrência, ou nasce uma
   * duplicada. Aborta em vez de escolher no escuro.
   */
  public static final String MSG_TRANSICAO_NAO_CARIMBADA = 'Não foi possível registrar a perda desta Oportunidade: a transição para "Perdido" não foi carimbada pela automação. A mudança foi cancelada — tente novamente. Se persistir, acione o administrador.';

  /** Falha controlada do encerramento por perda (CLICKUP-9425). */
  public class NegocioPerdidoException extends Exception {
  }

  /** Resultado controlado do encerramento por perda. */
  public class ResultadoPerda {
    /** Leads/Oportunidades que estavam realmente perdidos e no escopo. */
    public Integer negociosPerdidos = 0;
    /** Tasks abertas canceladas (de qualquer tipo, inclusive manuais). */
    public Integer tarefasCanceladas = 0;
    /** Tasks manuais (sem SOL_Tipo_Tarefa__c) entre as canceladas. */
    public Integer tarefasManuaisCanceladas = 0;
    /** Fora de escopo, sem o sinal exato de perda ou não encontrados. */
    public Integer ignorados = 0;
  }

  // ================================================== PREDICADOS (régua única)

  /**
   * Este Lead representa um negócio PERDIDO? Régua única, consumida pelos
   * guardas dos cards 9401–9424.
   *
   * Função PURA: nada de SOQL/DML. O chamador passa o Lead que já carregou
   * (idealmente com FOR UPDATE), com ao menos `Status`,
   * `SOL_Motivo_Desqualificacao__c` e `SOL_Opt_Out__c` na projeção.
   *
   * Exige o sinal COMPLETO — desqualificação com motivo de perda e sem opt-out.
   * Um Lead desqualificado por opt-out NÃO é "perdido" para este card: aquele
   * caminho é do CLICKUP-9418 e permanece isolado.
   */
  public static Boolean leadPerdido(Lead l) {
    return l != null &&
      l.Status == LEAD_STATUS_DESQUALIFICADO &&
      l.SOL_Motivo_Desqualificacao__c == MOTIVO_DESQUALIFICACAO_PERDA &&
      l.SOL_Opt_Out__c != true;
  }

  /**
   * Esta Oportunidade representa um negócio PERDIDO? Função PURA; o chamador
   * passa a Opportunity já carregada, com `StageName` na projeção.
   *
   * Observação: "Perdido" tem IsClosed = true, então os serviços que já exigem
   * `IsClosed == false` estão protegidos por construção — este predicado torna a
   * intenção explícita e cobre quem lê a etapa diretamente.
   */
  public static Boolean oportunidadePerdida(Opportunity o) {
    return o != null && o.StageName == ETAPA_PERDIDO;
  }

  // ================================================== ENTRADA 1 — LEAD

  /**
   * Encerra todas as Tasks abertas dos Leads que acabaram de ser perdidos antes
   * da conversão.
   *
   * @param leadIds Ids de Lead (qualquer origem; filtrados aqui).
   * @throws NegocioPerdidoException falha no cancelamento — aborta a perda.
   */
  public static ResultadoPerda encerrarPorLeadPerdido(List<Id> leadIds) {
    ResultadoPerda r = new ResultadoPerda();
    Set<Id> ids = idsDoTipo(leadIds, Lead.SObjectType);
    if (ids.isEmpty()) {
      return r;
    }

    Savepoint sp = null;
    try {
      sp = Database.setSavepoint();

      // FOR UPDATE: serializa com o opt-out, a distribuição e a reatribuição,
      // que também travam o Lead. Garante que o estado lido é o atual.
      Set<Id> perdidos = new Set<Id>();
      Set<Id> encontrados = new Set<Id>();
      for (Lead l : [
        SELECT
          Id,
          Status,
          IsConverted,
          RecordType.DeveloperName,
          SOL_Produto_Interesse__c,
          SOL_Motivo_Desqualificacao__c,
          SOL_Opt_Out__c
        FROM Lead
        WHERE Id IN :ids
        FOR UPDATE
      ]) {
        encontrados.add(l.Id);
        Boolean noEscopo =
          l.RecordType.DeveloperName == RECORD_TYPE_SOL &&
          PRODUTOS_NO_ESCOPO.contains(l.SOL_Produto_Interesse__c) &&
          // Perda ANTES da conversão.
          l.IsConverted == false &&
          leadPerdido(l);
        if (noEscopo) {
          perdidos.add(l.Id);
        } else {
          r.ignorados++;
        }
      }
      r.ignorados += (ids.size() - encontrados.size());

      if (perdidos.isEmpty()) {
        return r;
      }
      r.negociosPerdidos = perdidos.size();

      cancelarTarefasAbertas(perdidos, true, r);
      return r;
    } catch (Exception e) {
      if (sp != null) {
        Database.rollback(sp);
      }
      System.debug(
        LoggingLevel.ERROR,
        'SOLNegocioPerdidoService.lead: ' +
          e.getTypeName() +
          ': ' +
          e.getMessage() +
          '\n' +
          e.getStackTraceString()
      );
      throw new NegocioPerdidoException(MSG_FALHA_LEAD);
    }
  }

  // ================================================== ENTRADA 2 — OPPORTUNITY

  /**
   * Encerra todas as Tasks abertas das Oportunidades que acabaram de virar
   * "Perdido" e registra, na MESMA transação, a ocorrência "Oportunidade
   * perdida" do relatório de reatribuições e perdas (CLICKUP-9438).
   *
   * @param opportunityIds Ids de Opportunity (qualquer origem; filtrados aqui).
   * @param etapasAnteriores etapa REAL de onde cada Oportunidade saiu, por Id —
   *   `$Record__Prior.StageName` no Flow after-save. Obrigatória para toda
   *   Oportunidade que entrar no escopo; "Perdido" não vale (é o destino).
   * @throws NegocioPerdidoException falha no cancelamento, ou etapa anterior
   *   ausente/inválida — nos dois casos a perda é abortada.
   */
  public static ResultadoPerda encerrarPorOportunidadePerdida(
    List<Id> opportunityIds,
    Map<Id, String> etapasAnteriores
  ) {
    ResultadoPerda r = new ResultadoPerda();
    Set<Id> ids = idsDoTipo(opportunityIds, Opportunity.SObjectType);
    if (ids.isEmpty()) {
      return r;
    }

    Savepoint sp = null;
    try {
      sp = Database.setSavepoint();

      // (CLICKUP-9438) OwnerId entra na projeção: é o vendedor responsável no
      // instante da perda, e o evento o congela antes de qualquer transferência
      // posterior da Oportunidade. SOL_Qtd_Perdas__c é o número desta TRANSIÇÃO
      // para "Perdido", incrementado pelo Flow before-save no mesmo save que
      // fechou o negócio — é ele que identifica a ocorrência.
      Map<Id, Opportunity> perdidas = new Map<Id, Opportunity>();
      Set<Id> encontradas = new Set<Id>();
      for (Opportunity o : [
        SELECT
          Id,
          OwnerId,
          StageName,
          SOL_Produto_Negocio__c,
          SOL_Qtd_Perdas__c,
          RecordType.DeveloperName
        FROM Opportunity
        WHERE Id IN :ids
        FOR UPDATE
      ]) {
        encontradas.add(o.Id);
        Boolean noEscopo =
          o.RecordType.DeveloperName == RECORD_TYPE_SOL &&
          PRODUTOS_NO_ESCOPO.contains(o.SOL_Produto_Negocio__c) &&
          oportunidadePerdida(o);
        if (noEscopo) {
          perdidas.put(o.Id, o);
        } else {
          r.ignorados++;
        }
      }
      r.ignorados += (ids.size() - encontradas.size());

      if (perdidas.isEmpty()) {
        return r;
      }
      r.negociosPerdidos = perdidas.size();

      cancelarTarefasAbertas(perdidas.keySet(), false, r);

      // (CLICKUP-9438) Uma ocorrência por perda, no MESMO Savepoint: se ela não
      // puder ser gravada, o rollback desfaz o cancelamento das tarefas e a
      // exceção aborta a própria mudança para "Perdido" (o Flow chama com
      // flowTransactionModel = CurrentTransaction). Não existe perda sem
      // ocorrência, nem ocorrência sem perda.
      //
      // A etapa anterior é exigida ANTES de montar o evento, com mensagem
      // própria: "o Apex ignora" não é proteção — gravar a perda com etapa
      // vazia deixaria dado falso no relatório do gestor sem erro nenhum.
      Datetime agora = System.now();
      List<SOL_Evento_Jornada__c> eventos = new List<SOL_Evento_Jornada__c>();
      for (Opportunity o : perdidas.values()) {
        String etapaAnterior = etapasAnteriores == null
          ? null
          : etapasAnteriores.get(o.Id);
        if (
          String.isBlank(etapaAnterior) ||
          etapaAnterior == SOLEventoJornadaService.ETAPA_PERDIDO
        ) {
          throw new NegocioPerdidoException(MSG_ETAPA_ANTERIOR_AUSENTE);
        }
        // Sem o contador da transição não dá para saber se esta perda é a mesma
        // de antes ou uma nova depois de reabertura — e as duas respostas
        // erradas são graves: ou some uma ocorrência, ou nasce uma duplicada.
        // Aborta, em vez de escolher no escuro.
        if (o.SOL_Qtd_Perdas__c == null || o.SOL_Qtd_Perdas__c <= 0) {
          throw new NegocioPerdidoException(MSG_TRANSICAO_NAO_CARIMBADA);
        }
        eventos.add(
          SOLEventoJornadaService.oportunidadePerdida(
            o,
            etapaAnterior,
            o.SOL_Qtd_Perdas__c,
            agora
          )
        );
      }
      SOLEventoJornadaService.registrar(eventos);

      return r;
    } catch (NegocioPerdidoException e) {
      // Mensagem já controlada (etapa anterior ausente): preserva o texto em
      // vez de trocá-lo pelo genérico de cancelamento de tarefas.
      if (sp != null) {
        Database.rollback(sp);
      }
      System.debug(
        LoggingLevel.ERROR,
        'SOLNegocioPerdidoService.oportunidade: ' + e.getMessage()
      );
      throw e;
    } catch (Exception e) {
      if (sp != null) {
        Database.rollback(sp);
      }
      System.debug(
        LoggingLevel.ERROR,
        'SOLNegocioPerdidoService.oportunidade: ' +
          e.getTypeName() +
          ': ' +
          e.getMessage() +
          '\n' +
          e.getStackTraceString()
      );
      throw new NegocioPerdidoException(MSG_FALHA_OPORTUNIDADE);
    }
  }

  // ================================================== interno

  /**
   * Cancela TODAS as Tasks abertas dos pais informados — WhoId para Lead,
   * WhatId para Opportunity — sem filtrar por tipo, para alcançar também as
   * tarefas manuais. Uma consulta e uma gravação, sem laço de SOQL/DML.
   */
  private static void cancelarTarefasAbertas(
    Set<Id> paisPerdidos,
    Boolean porLead,
    ResultadoPerda r
  ) {
    List<Task> abertas = porLead
      ? [
          SELECT Id, SOL_Tipo_Tarefa__c
          FROM Task
          WHERE WhoId IN :paisPerdidos AND IsClosed = false
          FOR UPDATE
        ]
      : [
          SELECT Id, SOL_Tipo_Tarefa__c
          FROM Task
          WHERE WhatId IN :paisPerdidos AND IsClosed = false
          FOR UPDATE
        ];
    if (abertas.isEmpty()) {
      // Perda sem tarefa aberta: a mudança do pai segue normalmente.
      return;
    }

    List<Task> cancelar = new List<Task>();
    for (Task t : abertas) {
      if (String.isBlank(t.SOL_Tipo_Tarefa__c)) {
        r.tarefasManuaisCanceladas++;
      }
      // Status + motivo + flag na MESMA gravação: é o trio que distingue o
      // cancelamento por perda e o que autoriza a VR a aceitar tarefa manual
      // sem tipo técnico.
      cancelar.add(
        new Task(
          Id = t.Id,
          Status = TASK_STATUS_CANCELADA,
          SOL_Motivo_Cancelamento__c = MOTIVO_CANCELAMENTO_PERDA,
          SOL_Cancelada_Por_Perda__c = true
        )
      );
    }
    update cancelar;
    r.tarefasCanceladas = cancelar.size();
  }

  private static Set<Id> idsDoTipo(List<Id> entrada, Schema.SObjectType tipo) {
    Set<Id> ids = new Set<Id>();
    if (entrada == null) {
      return ids;
    }
    for (Id i : entrada) {
      if (i != null && i.getSObjectType() == tipo) {
        ids.add(i);
      }
    }
    return ids;
  }
}
