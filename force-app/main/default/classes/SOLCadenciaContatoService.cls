/**
 * CLICKUP-9434 — Criação da tarefa DIÁRIA de ligação da cadência de contato da
 * Arnone Soluções (Record Type `SOL`).
 *
 * ESCOPO DESTE CARD: o COMPONENTE de criação da tarefa de ligação, com um
 * contrato estável para o motor agendado da cadência (CLICKUP-9398), que será
 * implementado depois e é quem decide QUANDO cada dia ativo vence. Este serviço
 * não agenda nada, não varre Leads e não encerra cadência: ele apenas cria, de
 * forma idempotente, a tarefa de ligação de um dia ativo que lhe for pedido.
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
 * CONCORRÊNCIA — `criarLigacoes` trava os Leads com `FOR UPDATE` ANTES de ler as
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

  /** Canal desta cadência. Os cards de e-mail e WhatsApp reusam o campo. */
  public static final String CANAL_LIGACAO = 'Ligação';

  /** Primeiro dia ativo: a tarefa que a distribuição/reatribuição já cria. */
  public static final Integer DIA_PRIMEIRA_LIGACAO = 1;

  /** Último dia ativo previsto para a cadência de ligação. */
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

  /** Mensagem controlada — sem detalhe técnico sensível. */
  @TestVisible
  private static final String MSG_ERRO_GENERICO = 'Não foi possível criar as tarefas de ligação agora. Nenhuma alteração foi salva.';

  /**
   * Pedido de criação de UMA tarefa de ligação, emitido pelo motor da cadência.
   *
   * `leadId` e `dia` (1..3) são obrigatórios. `vencimento` é obrigatório nos
   * dias 2 e 3 e IGNORADO no dia 1, cujo prazo são 5 minutos úteis.
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
    /** Tarefas de ligação efetivamente criadas. */
    public Integer criadas = 0;
    /** Pedidos que já tinham tarefa para o mesmo Lead + ciclo + dia. */
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
    Resultado r = new Resultado();
    if (solicitacoes == null || solicitacoes.isEmpty()) {
      return r;
    }

    // (1) validação em memória — nenhum acesso ao banco para pedido inválido.
    List<Solicitacao> validas = new List<Solicitacao>();
    Set<Id> leadIds = new Set<Id>();
    for (Solicitacao s : solicitacoes) {
      if (!solicitacaoValida(s)) {
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
      Set<String> chavesOcupadas = chavesExistentes(elegiveis.keySet());

      Id bhId = SOLBusinessHoursHelper.businessHoursId();
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
        if (s.dia == DIA_PRIMEIRA_LIGACAO) {
          prazoContato = prazoPrimeiraLigacao(bhId, agora);
          vencimento = prazoContato.dateGmt();
        }
        novas.add(
          montarTarefa(
            l.Id,
            l.OwnerId,
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
        'SOLCadenciaContatoService.criarLigacoes: ' +
          e.getTypeName() +
          ': ' +
          e.getMessage() +
          '\n' +
          e.getStackTraceString()
      );
      // Resultado NOVO: as contagens parciais acima foram desfeitas.
      Resultado erro = new Resultado();
      erro.comErro = validas.size();
      erro.mensagens.add(MSG_ERRO_GENERICO);
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
   * Chave lógica da tarefa: Lead + canal + ciclo + dia. Os milissegundos do
   * ciclo são descartados porque campos DateTime do Salesforce têm precisão de
   * SEGUNDO — comparar o valor em memória com o valor relido do banco só é
   * confiável na mesma granularidade.
   */
  @TestVisible
  private static String chaveCadencia(Id leadId, Datetime ciclo, Integer dia) {
    if (leadId == null || ciclo == null || dia == null) {
      return null;
    }
    return String.valueOf(leadId).left(15) +
      '|' +
      CANAL_LIGACAO +
      '|' +
      String.valueOf(ciclo.getTime() / 1000) +
      '|' +
      String.valueOf(dia);
  }

  /** Pedido bem formado? Sem acesso ao banco. */
  private static Boolean solicitacaoValida(Solicitacao s) {
    if (s == null || s.leadId == null) {
      return false;
    }
    if (s.leadId.getSObjectType() != Lead.SObjectType) {
      return false;
    }
    if (s.dia == null || s.dia < DIA_PRIMEIRA_LIGACAO || s.dia > DIA_MAXIMO) {
      return false;
    }
    // Dias 2 e 3 dependem do dia útil que o motor calcula; sem ele não há
    // vencimento a gravar e o pedido é inválido (nunca "hoje" por suposição).
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
   * Chaves de cadência JÁ materializadas para estes Leads. Sem filtro de
   * Status de propósito: uma ligação daquele dia que já foi concluída ou
   * cancelada continua ocupando o dia — o reprocessamento não a recria.
   */
  private static Set<String> chavesExistentes(Set<Id> leadIds) {
    Set<String> chaves = new Set<String>();
    if (leadIds == null || leadIds.isEmpty()) {
      return chaves;
    }
    for (Task t : [
      SELECT WhoId, SOL_Ciclo_Contato__c, SOL_Dia_Cadencia__c
      FROM Task
      WHERE
        WhoId IN :leadIds
        AND SOL_Tipo_Tarefa__c = :TIPO_TAREFA_CONTATO
        AND SOL_Canal_Contato__c = :CANAL_LIGACAO
        AND SOL_Ciclo_Contato__c != NULL
        AND SOL_Dia_Cadencia__c != NULL
    ]) {
      chaves.add(
        chaveCadencia(
          t.WhoId,
          t.SOL_Ciclo_Contato__c,
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
   * Task de ligação com a classificação estruturada completa.
   * `SOL_Resultado_Contato__c` fica VAZIO: quem preenche é o vendedor, e a VR
   * `SOL_Resultado_Obrigatorio_Concluir` impede concluir sem ele.
   */
  private static Task montarTarefa(
    Id leadId,
    Id ownerId,
    Integer dia,
    Datetime ciclo,
    Date vencimento,
    Datetime prazoContato
  ) {
    return new Task(
      Subject = SUBJECT_POR_DIA.get(dia),
      WhoId = leadId,
      OwnerId = ownerId,
      Status = TASK_STATUS_ABERTO,
      ActivityDate = vencimento,
      SOL_Prazo_Contato__c = prazoContato,
      // CLICKUP-9417: classificador de tarefa de contato — é o que o
      // cancelamento por contato efetivado / opt-out / perda já procura.
      SOL_Tipo_Tarefa__c = TIPO_TAREFA_CONTATO,
      // CLICKUP-9434: canal + ciclo + dia = chave lógica da cadência.
      SOL_Canal_Contato__c = CANAL_LIGACAO,
      SOL_Ciclo_Contato__c = ciclo,
      SOL_Dia_Cadencia__c = dia
    );
  }
}
