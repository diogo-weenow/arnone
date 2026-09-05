/**
 * CLICKUP-9434 / 9435 — Criação das tarefas DIÁRIAS da cadência de contato da
 * Arnone Soluções (Record Type `SOL`): LIGAÇÃO e E-MAIL.
 *
 * ESCOPO: os COMPONENTES de criação, com um contrato estável para o motor
 * agendado da cadência (CLICKUP-9398), que será implementado depois e é quem
 * decide QUANDO cada dia ativo vence. Este serviço não agenda nada, não varre
 * Leads e não encerra cadência: ele apenas cria, de forma idempotente, a tarefa
 * do dia ativo que lhe for pedido.
 *
 * DUAS PORTAS, UM NÚCLEO (CLICKUP-9435) — `criarLigacoes` e `criarEmails` são
 * fachadas de uma linha sobre `criarTarefasDaCadencia`, que carrega o canal como
 * parâmetro PRIVADO. O canal viaja por LOTE, nunca dentro da `Solicitacao`:
 * cada chamada processa um único canal, então a chave de idempotência é sempre
 * construída com o mesmo canal que filtrou a consulta de chaves existentes, e
 * "ler a chave de um canal e atribuí-la a outro" é impossível por construção.
 * O DTO segue cego ao canal e a assinatura de `criarLigacoes` está intacta.
 *
 * E-MAIL x LIGAÇÃO — o que difere está isolado em três pontos: o vencimento é
 * obrigatório em TODOS os dias do e-mail (nada é derivado de prazo), o e-mail
 * não recebe `SOL_Prazo_Contato__c` e o resultado do envio mora em
 * `SOL_Resultado_Envio__c`. Ligação e e-mail COEXISTEM no mesmo Lead, ciclo e
 * dia, porque o canal entra na chave.
 *
 * DIA 1 — a Task "1ª Ligação" que a distribuição e a reatribuição já criavam
 * (CLICKUP-9396 / 9400) passa a ser, formalmente, a ligação do dia 1. A lógica
 * de montagem dela foi EXTRAÍDA para cá (`montarPrimeirasLigacoes`) e o
 * `SOLDistribuicaoService` delega para este serviço — não há uma segunda
 * automação concorrendo com a distribuição, e o prazo continua sendo de CINCO
 * MINUTOS ÚTEIS após a atribuição. Dentro do expediente o dia 1 começa
 * imediatamente; fora dele, `BusinessHours.add` empurra a contagem para a
 * próxima abertura útil — sem cálculo manual de fim de semana ou feriado.
 *
 * DIAS 2 E 3 — criados por `criarLigacoes`, com o vencimento (dia útil) que o
 * motor informar. Quem calcula esse dia útil é o motor; aqui o dia recebido é
 * gravado como está em `ActivityDate`. Tarefa não concluída permanece ABERTA e
 * vencida: este serviço nunca fecha nem reprograma tarefa existente.
 *
 * IDEMPOTÊNCIA — a chave lógica é (Lead, ciclo de contato, canal, dia), gravada
 * em campos ESTRUTURADOS (`SOL_Ciclo_Contato__c`, `SOL_Canal_Contato__c`,
 * `SOL_Dia_Cadencia__c`) e NUNCA no `Subject`, que o vendedor pode editar.
 * Reprocessar o mesmo pedido não cria duplicata — inclusive quando a tarefa
 * anterior já foi concluída ou cancelada, porque a checagem ignora o Status.
 *
 * CONCORRÊNCIA — o núcleo trava os Leads com `FOR UPDATE` ANTES de ler as
 * tarefas existentes. Duas execuções simultâneas sobre o mesmo Lead são
 * serializadas pelo banco: a segunda só lê depois do commit da primeira e
 * enxerga a tarefa que ela criou. Nenhum lock de singleton é tomado aqui, então
 * não há inversão da ordem de locks usada por `SOLDistribuicaoService`. O
 * caminho do dia 1 na distribuição não precisa desse lock: ele roda dentro da
 * transação que ACABOU de abrir o ciclo, já serializada pelo lock do singleton,
 * e a chave (ciclo novo) é inédita por construção.
 *
 * Bulk-safe: nenhum SOQL/DML dentro de laço. Contexto de sistema, como os
 * demais serviços da jornada — a automação precisa gravar independentemente do
 * permission set do usuário que disparou o Flow.
 */
public without sharing class SOLCadenciaContatoService {
  /** Record Type de Lead atendido — nenhuma outra BU é afetada. */
  public static final String RECORD_TYPE_DEVELOPER_NAME = 'SOL';

  /** Canal de LIGAÇÃO da cadência. */
  public static final String CANAL_LIGACAO = 'Ligação';

  /**
   * Canal de E-MAIL da cadência (CLICKUP-9435). Grafia byte-exata do value set
   * restrito de `SOL_Canal_Contato__c`: hífen e "E" maiúsculo.
   */
  public static final String CANAL_EMAIL = 'E-mail';

  /** Primeiro dia ativo: a tarefa que a distribuição/reatribuição já cria. */
  public static final Integer DIA_PRIMEIRA_LIGACAO = 1;

  /** Último dia ativo previsto para a cadência, nos dois canais. */
  public static final Integer DIA_MAXIMO = 3;

  /** Classificador técnico compartilhado com o CLICKUP-9417 (cancelamentos). */
  @TestVisible
  private static final String TIPO_TAREFA_CONTATO = 'Contato';

  /** Valor de Status aberto válido na org (TaskStatus IsClosed = false). */
  @TestVisible
  private static final String TASK_STATUS_ABERTO = 'Open';

  /** Prazo do dia 1: 5 minutos ÚTEIS após a atribuição (CLICKUP-9396). */
  @TestVisible
  private static final Long PRAZO_PRIMEIRA_LIGACAO_MS = 5L * 60L * 1000L;

  /**
   * Assunto exibido ao vendedor. É RÓTULO, não chave: "1ª Ligação" é mantido
   * literalmente para não quebrar relatórios e testes existentes.
   */
  @TestVisible
  private static final Map<Integer, String> SUBJECT_POR_DIA = new Map<Integer, String>{
    1 => '1ª Ligação',
    2 => '2ª Ligação',
    3 => '3ª Ligação'
  };

  /**
   * Rótulo das tarefas de e-mail (CLICKUP-9435). Também é RÓTULO, nunca chave:
   * o vendedor pode editar o Subject e a idempotência não depende dele.
   */
  @TestVisible
  private static final Map<Integer, String> SUBJECT_EMAIL_POR_DIA = new Map<Integer, String>{
    1 => '1º E-mail',
    2 => '2º E-mail',
    3 => '3º E-mail'
  };

  /** Mensagem controlada — sem detalhe técnico sensível. */
  @TestVisible
  private static final String MSG_ERRO_GENERICO = 'Não foi possível criar as tarefas de ligação agora. Nenhuma alteração foi salva.';

  /** Mensagem controlada do canal e-mail (CLICKUP-9435). */
  @TestVisible
  private static final String MSG_ERRO_GENERICO_EMAIL = 'Não foi possível criar as tarefas de e-mail agora. Nenhuma alteração foi salva.';

  /**
   * Pedido de criação de UMA tarefa de contato, emitido pelo motor da cadência.
   *
   * `leadId` e `dia` (1..3) são obrigatórios. O significado de `vencimento`
   * depende da PORTA usada, não de um campo de canal — o DTO é deliberadamente
   * cego ao canal (CLICKUP-9435):
   *
   * - por `criarLigacoes`: obrigatório nos dias 2 e 3 e IGNORADO no dia 1, cujo
   *   prazo são 5 minutos úteis a partir da atribuição;
   * - por `criarEmails`: OBRIGATÓRIO em todos os dias, inclusive no dia 1 — não
   *   existe "e-mail 5 minutos após a atribuição", quem decide o dia útil é o
   *   motor.
   */
  public class Solicitacao {
    public Id leadId;
    public Integer dia;
    public Date vencimento;

    public Solicitacao() {
    }

    public Solicitacao(Id leadId, Integer dia, Date vencimento) {
      this.leadId = leadId;
      this.dia = dia;
      this.vencimento = vencimento;
    }
  }

  /** Resultado controlado. Sem detalhe técnico sensível. */
  public class Resultado {
    /** Tarefas efetivamente criadas no canal da porta chamada. */
    public Integer criadas = 0;
    /** Pedidos que já tinham tarefa para o mesmo Lead + ciclo + canal + dia. */
    public Integer jaExistentes = 0;
    /** Pedidos inválidos ou de Lead fora do escopo da cadência. */
    public Integer ignoradas = 0;
    /** Pedidos perdidos por falha controlada (tudo revertido). */
    public Integer comErro = 0;
    public List<String> mensagens = new List<String>();
  }

  // =====================================================================
  //  API DO MOTOR DA CADÊNCIA (CLICKUP-9398)
  // =====================================================================

  /**
   * Cria, em bulk e de forma idempotente, a tarefa de ligação de cada pedido.
   *
   * Um pedido é IGNORADO (sem erro) quando: não tem Lead ou dia válido; é dia 2
   * ou 3 sem vencimento; o Lead não existe, foi convertido ou não é do Record
   * Type `SOL`; o Lead ainda não tem ciclo de contato aberto (não distribuído,
   * ou em fallback para a fila); ou a cadência daquele Lead já foi encerrada —
   * contato efetivado, opt-out ou negócio perdido. Esse último filtro é uma
   * TRAVA DEFENSIVA derivada das regras já implementadas (CLICKUP-9417 / 9418 /
   * 9425): este serviço não encerra nada e não altera aquelas regras, apenas se
   * recusa a abrir uma tarefa nova numa cadência que já acabou.
   *
   * Falha controlada: rollback total ao Savepoint próprio e `comErro` — nada
   * fica pela metade e a falha não é descartada em silêncio.
   *
   * @param solicitacoes pedidos do motor. Nulo/vazio devolve resultado zerado.
   */
  public static Resultado criarLigacoes(List<Solicitacao> solicitacoes) {
    return criarTarefasDaCadencia(solicitacoes, CANAL_LIGACAO);
  }

  /**
   * Cria, em bulk e de forma idempotente, a tarefa de E-MAIL de cada pedido
   * (CLICKUP-9435). Porta gêmea de `criarLigacoes`: mesmo núcleo de
   * elegibilidade, lock, idempotência e atomicidade; o que muda é o CANAL, que
   * viaja por LOTE e não dentro da `Solicitacao` — nenhum parâmetro público de
   * canal é exposto.
   *
   * Diferenças de contrato em relação à ligação, todas derivadas do card:
   *
   * - `vencimento` é OBRIGATÓRIO em TODOS os dias, inclusive o dia 1. Não há
   *   "e-mail 5 minutos úteis após a atribuição": quem calcula o dia útil é o
   *   motor, e o valor recebido é gravado em `ActivityDate` como está;
   * - `SOL_Prazo_Contato__c` fica NULO — aquele campo é o SLA de 5 minutos da
   *   primeira LIGAÇÃO e é o que ativa o primeiro ramo da VR
   *   `SOL_Resultado_Obrigatorio_Concluir`. Deixá-lo nulo é o que mantém a VR de
   *   ligação inerte sobre a tarefa de e-mail, cuja obrigatoriedade de resultado
   *   é imposta pela VR própria `SOL_Resultado_Envio_Obrigatorio`;
   * - o resultado do envio mora em `SOL_Resultado_Envio__c`, JAMAIS em
   *   `SOL_Resultado_Contato__c` — a VR `SOL_Email_Sem_Resultado_Ligacao`
   *   bloqueia essa mistura, porque os três Flows de contato efetivado, opt-out
   *   e reatribuição disparam por VALOR daquele campo e são cegos ao canal.
   *
   * Um pedido é IGNORADO (sem erro) pelas mesmas razões da ligação, mais a
   * ausência de vencimento em qualquer dia.
   *
   * @param solicitacoes pedidos do motor. Nulo/vazio devolve resultado zerado.
   */
  public static Resultado criarEmails(List<Solicitacao> solicitacoes) {
    return criarTarefasDaCadencia(solicitacoes, CANAL_EMAIL);
  }

  // =====================================================================
  //  NÚCLEO PRIVADO COMPARTILHADO PELAS DUAS PORTAS (CLICKUP-9435)
  // =====================================================================

  /**
   * Corpo único de criação, parametrizado pelo canal do LOTE. Extraído de
   * `criarLigacoes` sem alterar uma linha do comportamento de ligação: a única
   * generalização é o canal, que entra na chave de idempotência, no filtro e na
   * projeção da consulta de chaves, no Subject e no campo gravado.
   *
   * O canal é privado de propósito: cada porta pública processa UM canal por
   * chamada, então a chave é sempre construída com o mesmo canal que filtrou a
   * consulta — o defeito de "ler chave de um canal e atribuí-la a outro" é
   * impossível por construção, e não apenas evitado por cuidado.
   */
  private static Resultado criarTarefasDaCadencia(
    List<Solicitacao> solicitacoes,
    String canal
  ) {
    Resultado r = new Resultado();
    if (solicitacoes == null || solicitacoes.isEmpty()) {
      return r;
    }

    // (1) validação em memória — nenhum acesso ao banco para pedido inválido.
    List<Solicitacao> validas = new List<Solicitacao>();
    Set<Id> leadIds = new Set<Id>();
    for (Solicitacao s : solicitacoes) {
      if (!solicitacaoValida(s, canal)) {
        r.ignoradas++;
        continue;
      }
      validas.add(s);
      leadIds.add(s.leadId);
    }
    if (validas.isEmpty()) {
      return r;
    }

    Savepoint sp = Database.setSavepoint();
    try {
      // (2) LOCK primeiro: serializa duas execuções sobre o mesmo Lead.
      Map<Id, Lead> elegiveis = carregarLeadsElegiveis(leadIds);

      // (3) chaves já materializadas — lidas DEPOIS do lock, uma única vez.
      Set<String> chavesOcupadas = chavesExistentes(elegiveis.keySet(), canal);

      // O calendário só é resolvido no caminho que realmente usa prazo em
      // minutos úteis. O e-mail não tem SLA de minutos e não paga essa consulta.
      Boolean usaPrazoDeAtribuicao = CANAL_LIGACAO.equals(canal);
      Id bhId = usaPrazoDeAtribuicao
        ? SOLBusinessHoursHelper.businessHoursId()
        : null;
      Datetime agora = System.now();

      List<Task> novas = new List<Task>();
      for (Solicitacao s : validas) {
        Lead l = elegiveis.get(s.leadId);
        if (l == null) {
          r.ignoradas++;
          continue;
        }
        String chave = chaveCadencia(
          l.Id,
          l.SOL_Data_Inicio_Ciclo_Contato__c,
          canal,
          s.dia
        );
        // Cobre a duplicata já gravada E a duplicata dentro do próprio lote.
        if (chavesOcupadas.contains(chave)) {
          r.jaExistentes++;
          continue;
        }
        chavesOcupadas.add(chave);

        Datetime prazoContato = null;
        Date vencimento = s.vencimento;
        if (usaPrazoDeAtribuicao && s.dia == DIA_PRIMEIRA_LIGACAO) {
          prazoContato = prazoPrimeiraLigacao(bhId, agora);
          vencimento = prazoContato.dateGmt();
        }
        novas.add(
          montarTarefa(
            l.Id,
            l.OwnerId,
            canal,
            s.dia,
            l.SOL_Data_Inicio_Ciclo_Contato__c,
            vencimento,
            prazoContato
          )
        );
      }

      if (!novas.isEmpty()) {
        insert novas;
        r.criadas = novas.size();
      }
      return r;
    } catch (Exception e) {
      Database.rollback(sp);
      System.debug(
        LoggingLevel.ERROR,
        'SOLCadenciaContatoService.criarTarefasDaCadencia(' +
          canal +
          '): ' +
          e.getTypeName() +
          ': ' +
          e.getMessage() +
          '\n' +
          e.getStackTraceString()
      );
      // Resultado NOVO: as contagens parciais acima foram desfeitas.
      Resultado erro = new Resultado();
      erro.comErro = validas.size();
      erro.mensagens.add(
        CANAL_LIGACAO.equals(canal) ? MSG_ERRO_GENERICO : MSG_ERRO_GENERICO_EMAIL
      );
      return erro;
    }
  }

  // =====================================================================
  //  DIA 1 — CAMINHO DA DISTRIBUIÇÃO / REATRIBUIÇÃO (CLICKUP-9396 / 9400)
  // =====================================================================

  /**
   * Monta (SEM DML) a ligação do DIA 1 para cada Lead recém-atribuído. Extraída
   * de `SOLDistribuicaoService.montarTasksPrimeiraLigacao` — o chamador insere
   * as Tasks dentro do próprio Savepoint, preservando a atomicidade de
   * "atribuiu ⇒ criou a tarefa" que já existia.
   *
   * Cada Lead precisa trazer `Id`, `OwnerId` e `SOL_Data_Inicio_Ciclo_Contato__c`
   * JÁ com os valores do ciclo que está sendo aberto — na reatribuição o ciclo
   * não é necessariamente `atribuicao`, e é o ciclo que entra na chave.
   *
   * Não faz SOQL em laço: o Business Hours é resolvido uma vez.
   *
   * ENTRADA INVÁLIDA é IGNORADA, nunca vira Task pela metade: item nulo, sem
   * `Id`, sem ciclo, ou com `OwnerId` que não seja de User (Lead em fallback
   * para a fila — `Task.OwnerId` não aceita Group) são descartados. O caminho
   * da distribuição nunca cai aqui: ele só passa Leads que acabaram de receber
   * um vendedor ativo e o ciclo recém-aberto. A guarda existe porque este é um
   * método PÚBLICO e uma Task sem dono ou sem ciclo quebraria a idempotência.
   *
   * @param atribuidos Leads que acabaram de ser atribuídos/reatribuídos.
   * @param atribuicao instante da atribuição — origem dos 5 minutos úteis.
   */
  public static List<Task> montarPrimeirasLigacoes(
    List<Lead> atribuidos,
    Datetime atribuicao
  ) {
    List<Task> tarefas = new List<Task>();
    if (atribuidos == null || atribuidos.isEmpty() || atribuicao == null) {
      return tarefas;
    }
    Id bhId = SOLBusinessHoursHelper.businessHoursId();
    Datetime prazo = prazoPrimeiraLigacao(bhId, atribuicao);
    for (Lead l : atribuidos) {
      if (!podeReceberTarefa(l)) {
        continue;
      }
      tarefas.add(
        montarTarefa(
          l.Id,
          l.OwnerId,
          // A distribuição só cria LIGAÇÃO: não existe "e-mail 5 minutos úteis
          // após a atribuição", e o e-mail entra apenas pelo motor.
          CANAL_LIGACAO,
          DIA_PRIMEIRA_LIGACAO,
          l.SOL_Data_Inicio_Ciclo_Contato__c,
          prazo.dateGmt(),
          prazo
        )
      );
    }
    return tarefas;
  }

  /**
   * Este Lead, como veio em memória, tem o mínimo para virar uma tarefa de
   * ligação válida e idempotente? Função PURA — não consulta o banco.
   */
  private static Boolean podeReceberTarefa(Lead l) {
    return l != null &&
      l.Id != null &&
      l.SOL_Data_Inicio_Ciclo_Contato__c != null &&
      l.OwnerId != null &&
      l.OwnerId.getSObjectType() == User.SObjectType;
  }

  // =====================================================================
  //  INTERNOS
  // =====================================================================

  /**
   * Chave lógica da tarefa: Lead + canal + ciclo + dia. O canal passou a ser
   * PARÂMETRO (CLICKUP-9435): antes era a constante de ligação embutida, o que
   * fazia ligação e e-mail disputarem a mesma chave. Com o canal recebido, os
   * dois canais coexistem no mesmo Lead, ciclo e dia sem se bloquearem.
   *
   * Os milissegundos do ciclo são descartados porque campos DateTime do
   * Salesforce têm precisão de SEGUNDO — comparar o valor em memória com o
   * valor relido do banco só é confiável na mesma granularidade.
   */
  @TestVisible
  private static String chaveCadencia(
    Id leadId,
    Datetime ciclo,
    String canal,
    Integer dia
  ) {
    if (leadId == null || ciclo == null || dia == null || String.isBlank(canal)) {
      return null;
    }
    return String.valueOf(leadId).left(15) +
      '|' +
      canal +
      '|' +
      String.valueOf(ciclo.getTime() / 1000) +
      '|' +
      String.valueOf(dia);
  }

  /**
   * Pedido bem formado para o canal do lote? Sem acesso ao banco.
   *
   * A exigência de `vencimento` é o único ponto em que o canal muda a
   * validação, e é por isso que ela recebe o canal (CLICKUP-9435): na ligação o
   * dia 1 dispensa o vencimento porque ele é DERIVADO dos 5 minutos úteis; no
   * e-mail nada é derivado, então o vencimento é obrigatório em todos os dias.
   * Sem esse recorte, um pedido de e-mail de dia 1 sem vencimento passaria a
   * validação e nasceria uma Task com `ActivityDate` nulo.
   */
  private static Boolean solicitacaoValida(Solicitacao s, String canal) {
    if (s == null || s.leadId == null) {
      return false;
    }
    if (s.leadId.getSObjectType() != Lead.SObjectType) {
      return false;
    }
    if (s.dia == null || s.dia < DIA_PRIMEIRA_LIGACAO || s.dia > DIA_MAXIMO) {
      return false;
    }
    if (!CANAL_LIGACAO.equals(canal)) {
      // E-mail: o dia útil vem pronto do motor em TODOS os dias.
      return s.vencimento != null;
    }
    // Ligação, dias 2 e 3: dependem do dia útil que o motor calcula; sem ele não
    // há vencimento a gravar e o pedido é inválido (nunca "hoje" por suposição).
    return s.dia == DIA_PRIMEIRA_LIGACAO || s.vencimento != null;
  }

  /**
   * Leads que podem receber tarefa de ligação, TRAVADOS para a transação. O
   * filtro roda em memória sobre a leitura com `FOR UPDATE`, então reflete o
   * estado confirmado do banco (mesmo padrão do `SOLDistribuicaoService`).
   */
  private static Map<Id, Lead> carregarLeadsElegiveis(Set<Id> leadIds) {
    Map<Id, Lead> elegiveis = new Map<Id, Lead>();
    for (Lead l : [
      SELECT
        Id,
        OwnerId,
        RecordType.DeveloperName,
        SOL_Data_Inicio_Ciclo_Contato__c,
        SOL_Contato_Efetivado__c,
        SOL_Opt_Out__c,
        Status,
        SOL_Motivo_Desqualificacao__c
      FROM Lead
      WHERE Id IN :leadIds AND IsConverted = FALSE
      FOR UPDATE
    ]) {
      // Outra BU: ignorado sem efeito colateral.
      if (l.RecordType.DeveloperName != RECORD_TYPE_DEVELOPER_NAME) {
        continue;
      }
      // Sem ciclo aberto não há cadência (Lead não distribuído); em fallback
      // para a fila o Owner é um Group, e `Task.OwnerId` exige User.
      if (!podeReceberTarefa(l)) {
        continue;
      }
      // (CLICKUP-9417) contato efetivado encerra a cadência.
      if (l.SOL_Contato_Efetivado__c == true) {
        continue;
      }
      // (CLICKUP-9418) opt-out encerra a cadência.
      if (l.SOL_Opt_Out__c == true) {
        continue;
      }
      // (CLICKUP-9425) negócio perdido encerra a cadência.
      if (SOLNegocioPerdidoService.leadPerdido(l)) {
        continue;
      }
      elegiveis.put(l.Id, l);
    }
    return elegiveis;
  }

  /**
   * Chaves de cadência JÁ materializadas para estes Leads, no canal do lote.
   *
   * Sem filtro de Status de propósito: uma tarefa daquele dia que já foi
   * concluída ou cancelada continua ocupando o dia — o reprocessamento não a
   * recria.
   *
   * O canal entra em DOIS lugares (CLICKUP-9435): no filtro, para não ler as
   * chaves do outro canal, e na PROJEÇÃO, para que a chave seja montada com o
   * valor real gravado na linha em vez de uma constante presumida. Projetar é o
   * que impede o defeito silencioso de marcar toda chave lida com o canal
   * errado — o que faria as ligações existentes bloquearem a criação dos
   * e-mails, sem erro e sem rastro.
   */
  private static Set<String> chavesExistentes(Set<Id> leadIds, String canal) {
    Set<String> chaves = new Set<String>();
    if (leadIds == null || leadIds.isEmpty() || String.isBlank(canal)) {
      return chaves;
    }
    for (Task t : [
      SELECT WhoId, SOL_Canal_Contato__c, SOL_Ciclo_Contato__c, SOL_Dia_Cadencia__c
      FROM Task
      WHERE
        WhoId IN :leadIds
        AND SOL_Tipo_Tarefa__c = :TIPO_TAREFA_CONTATO
        AND SOL_Canal_Contato__c = :canal
        AND SOL_Ciclo_Contato__c != NULL
        AND SOL_Dia_Cadencia__c != NULL
    ]) {
      chaves.add(
        chaveCadencia(
          t.WhoId,
          t.SOL_Ciclo_Contato__c,
          t.SOL_Canal_Contato__c,
          t.SOL_Dia_Cadencia__c.intValue()
        )
      );
    }
    return chaves;
  }

  /**
   * Prazo do dia 1: 5 minutos ÚTEIS após `atribuicao`. Dentro do expediente
   * começa na hora; fora dele `BusinessHours.add` empurra para a próxima
   * abertura útil. Sem calendário disponível, degrada para 5 minutos corridos —
   * comportamento herdado do CLICKUP-9396, preservado para não travar a
   * distribuição numa org sem o Business Hours implantado.
   */
  private static Datetime prazoPrimeiraLigacao(Id bhId, Datetime atribuicao) {
    return (bhId != null)
      ? BusinessHours.add(bhId, atribuicao, PRAZO_PRIMEIRA_LIGACAO_MS)
      : atribuicao.addMinutes(5);
  }

  /**
   * Task de contato do canal informado, com a classificação estruturada
   * completa.
   *
   * NENHUM dos dois campos de resultado é gravado aqui: `SOL_Resultado_Contato__c`
   * (ligação) e `SOL_Resultado_Envio__c` (e-mail) nascem VAZIOS, porque quem
   * preenche é o vendedor ao concluir — e é exatamente esse vazio que as VRs
   * `SOL_Resultado_Obrigatorio_Concluir` e `SOL_Resultado_Envio_Obrigatorio`
   * têm o que bloquear.
   *
   * O Subject é RÓTULO por canal e dia, nunca chave: o vendedor pode editá-lo e
   * a idempotência não olha para ele.
   */
  private static Task montarTarefa(
    Id leadId,
    Id ownerId,
    String canal,
    Integer dia,
    Datetime ciclo,
    Date vencimento,
    Datetime prazoContato
  ) {
    return new Task(
      Subject = subjectDe(canal, dia),
      WhoId = leadId,
      OwnerId = ownerId,
      Status = TASK_STATUS_ABERTO,
      ActivityDate = vencimento,
      SOL_Prazo_Contato__c = prazoContato,
      // CLICKUP-9417: classificador de tarefa de contato — é o que o
      // cancelamento por contato efetivado / opt-out / perda já procura, e é
      // por ele que a tarefa de e-mail herda os três cancelamentos de graça.
      SOL_Tipo_Tarefa__c = TIPO_TAREFA_CONTATO,
      // CLICKUP-9434/9435: canal + ciclo + dia = chave lógica da cadência.
      SOL_Canal_Contato__c = canal,
      SOL_Ciclo_Contato__c = ciclo,
      SOL_Dia_Cadencia__c = dia
    );
  }

  /** Rótulo visível ao vendedor, por canal e dia. Nunca chave técnica. */
  @TestVisible
  private static String subjectDe(String canal, Integer dia) {
    return CANAL_LIGACAO.equals(canal)
      ? SUBJECT_POR_DIA.get(dia)
      : SUBJECT_EMAIL_POR_DIA.get(dia);
  }
}
