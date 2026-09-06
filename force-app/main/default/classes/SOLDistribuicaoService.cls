/**
 * CLICKUP-9394 — Round-robin de distribuição de Leads do Record Type SOL
 * ("Arnone Soluções").
 *
 * ETAPA 5.1 — lógica Apex da distribuição. É chamada pela camada de
 * acionamento (SOLDistribuicaoInvocable, a partir do Flow SOL_Distribuir_Lead)
 * com uma coleção de IDs de Lead.
 *
 * Infraestrutura interna executada em CONTEXTO DE SISTEMA. O Apex, por padrão,
 * roda em contexto de sistema e não aplica checagem explícita de CRUD nem de
 * FLS. A classe não faz `WITH USER_MODE` / `WITH SECURITY_ENFORCED` /
 * `stripInaccessible` de propósito: precisa operar sobre a fila, seus membros,
 * o singleton e os Leads independentemente da origem (Web-to-Lead como
 * convidado, integração, usuário interno) e sem depender de permission set.
 *
 * `without sharing` controla apenas o compartilhamento em nível de REGISTRO
 * (row-level); não tem efeito sobre CRUD ou FLS.
 *
 * Premissas:
 * - A fila Fila_Leads_SOL é o cadastro oficial dos vendedores.
 * - Participam só usuários DIRETOS, ATIVOS e membros da fila. Grupos, papéis ou
 *   filas aninhados são ignorados.
 * - Manutenção da fila: time administrador Salesforce. Permission Set não é roster.
 */
public without sharing class SOLDistribuicaoService {
  /** Record Type de Lead atendido por este serviço. Regra fixa. */
  public static final String RECORD_TYPE_DEVELOPER_NAME = 'SOL';

  /** DeveloperName da fila: cadastro dos vendedores e fallback da distribuição. */
  public static final String QUEUE_DEVELOPER_NAME = 'Fila_Leads_SOL';

  /** Valor de Chave__c do registro singleton de estado. */
  @TestVisible
  private static final String SINGLETON_KEY = 'SOL';

  @TestVisible
  private static final String STATUS_DISTRIBUIDO = 'Distribuido';
  @TestVisible
  private static final String STATUS_FALLBACK = 'Fallback';
  @TestVisible
  private static final String STATUS_ERRO = 'Erro';

  // ---- CLICKUP-9400 / 9396: reatribuição por falta de contato ----

  /** Resultados negativos no ciclo do vendedor atual que disparam a troca. */
  @TestVisible
  private static final Integer TENTATIVAS_PARA_REATRIBUIR = 3;

  /** Contato efetivado: impede a reatribuição do ciclo atual (CLICKUP-9396). */
  @TestVisible
  private static final String RESULTADO_ATENDEU = 'Atendeu';
  @TestVisible
  private static final String RESULTADO_NAO_ATENDEU = 'Não atendeu';
  @TestVisible
  private static final String RESULTADO_NAO_FOI_POSSIVEL = 'Não foi possível ligar';

  /**
   * (CLICKUP-9437) Falou com o lead, mas o assunto NÃO avançou. Não é contato
   * efetivado — não marca o Lead, não preenche data e não cancela tarefa —, mas
   * CONTA como tentativa na régua de três.
   *
   * O valor é o API NAME da picklist, ASCII de propósito: `TEXT()` de picklist
   * devolve o API name, e é ele que o `filterFormula` do Flow de reatribuição
   * compara. Rótulo e API name são deliberadamente diferentes; nunca comparar
   * pelo rótulo ("Atendeu — sem conclusão").
   */
  @TestVisible
  private static final String RESULTADO_ATENDEU_SEM_CONCLUSAO = 'Atendeu_Sem_Conclusao';

  /** Resultados que contam como tentativa sem contato. */
  @TestVisible
  private static final Set<String> RESULTADOS_NEGATIVOS = new Set<String>{
    RESULTADO_ATENDEU_SEM_CONCLUSAO,
    RESULTADO_NAO_ATENDEU,
    RESULTADO_NAO_FOI_POSSIVEL
  };
  /**
   * Todos os resultados considerados na contagem do ciclo.
   *
   * (CLICKUP-9437) `RESULTADO_ATENDEU_SEM_CONCLUSAO` entra nos DOIS Sets, e não
   * é redundância. `RESULTADOS_NEGATIVOS` decide o que INCREMENTA a contagem;
   * `RESULTADOS_CONSIDERADOS` é o que vai para o `WHERE ... IN` da consulta de
   * Tasks e, por consequência, alimenta `ultimaConclusaoNoCiclo` — a base do
   * novo `SOL_Data_Inicio_Ciclo_Contato__c` ("última conclusão contada + 1s").
   *
   * Se o valor ficasse de fora daqui, a tarefa que disparou a troca não entraria
   * naquele cálculo, o ciclo novo começaria ANTES dela e ela voltaria a contar
   * na avaliação seguinte — reatribuindo o mesmo Lead em CASCATA. É este Set que
   * impede o loop.
   */
  @TestVisible
  private static final Set<String> RESULTADOS_CONSIDERADOS = new Set<String>{
    RESULTADO_ATENDEU,
    RESULTADO_ATENDEU_SEM_CONCLUSAO,
    RESULTADO_NAO_ATENDEU,
    RESULTADO_NAO_FOI_POSSIVEL
  };

  @TestVisible
  private static final String REATRIB_EM_ACOMPANHAMENTO = 'Em acompanhamento';
  @TestVisible
  private static final String REATRIB_REATRIBUIDO = 'Reatribuido';
  @TestVisible
  private static final String REATRIB_SEM_OUTRO_VENDEDOR = 'Sem outro vendedor';

  @TestVisible
  private static final String MOTIVO_REATRIBUICAO = 'Sem contato após 3 tentativas';
  @TestVisible
  private static final String MOTIVO_SEM_OUTRO_VENDEDOR = 'Não havia outro vendedor ativo disponível na fila.';

  // ---- CLICKUP-9396: Task "1ª Ligação" + prazo em horário comercial ----
  // (CLICKUP-9434) O assunto, o Status inicial e o cálculo do prazo saíram
  // daqui: a "1ª Ligação" é o dia 1 da cadência e é montada por
  // `SOLCadenciaContatoService`, que também atende os dias 2 e 3.

  // ---- CLICKUP-9417: classificação e cancelamento de tarefas de contato ----

  /** Classificador técnico da tarefa de contato SOL (não usar o Subject). */
  @TestVisible
  private static final String TIPO_TAREFA_CONTATO = 'Contato';
  /** Status "Cancelada" (TaskStatus closed) — tarefa encerrada pelo sistema. */
  @TestVisible
  private static final String TASK_STATUS_CANCELADA = 'Cancelada';
  /** Motivo do cancelamento quando o contato com o Lead foi efetivado. */
  @TestVisible
  private static final String MOTIVO_CANCELAMENTO_CONTATO_EFETIVADO = 'Contato efetivado';

  // ---- CLICKUP-9418: opt-out (Lead pede para não ser mais contatado) ----

  /** Resultado da tarefa de contato quando o Lead pede opt-out. */
  @TestVisible
  private static final String RESULTADO_OPT_OUT = 'Opt-out';
  /** Motivo do cancelamento das tarefas pendentes por opt-out. */
  @TestVisible
  private static final String MOTIVO_CANCELAMENTO_OPT_OUT = 'Opt-out';
  /** Motivo estruturado da desqualificação do Lead por opt-out. */
  @TestVisible
  private static final String MOTIVO_DESQUALIFICACAO_OPT_OUT = 'Opt-out';
  /** Status de perda do Lead na org (já existente). */
  @TestVisible
  private static final String LEAD_STATUS_DESQUALIFICADO = 'Desqualificado';

  /** Mensagens controladas — sem detalhe técnico sensível. */
  @TestVisible
  private static final String MSG_ERRO_GENERICO = 'A distribuição não pôde ser concluída agora. O lead será reprocessado.';
  @TestVisible
  private static final String MSG_CONFIG = 'A distribuição está temporariamente indisponível. Acione o administrador.';

  /** Costura de teste: aponta o serviço para uma fila sintética. */
  @TestVisible
  private static String queueDeveloperNameOverride;

  /** Costura de teste: simula ausência do singleton sem apagar dados. */
  @TestVisible
  private static String singletonKeyOverride;

  public virtual class DistribuicaoException extends Exception {
  }
  public class FilaInexistenteException extends DistribuicaoException {
  }
  public class FilaInvalidaException extends DistribuicaoException {
  }
  public class SingletonAusenteException extends DistribuicaoException {
  }
  public class RosterVazioException extends DistribuicaoException {
  }

  /** Resultado controlado da distribuição. Sem detalhe técnico sensível. */
  public class Resultado {
    public Integer distribuidos = 0;
    public Integer emFallback = 0;
    public Integer ignorados = 0;
    public Integer comErro = 0;
    public List<String> mensagens = new List<String>();
  }

  /**
   * Falha controlada do cancelamento por contato efetivado (CLICKUP-9417).
   * Lançada para ABORTAR a transação inteira: se as tarefas pendentes não
   * puderem ser canceladas, a própria conclusão da Task é desfeita e o vendedor
   * recebe esta mensagem para tentar de novo (operação atômica, sem estado
   * inconsistente e sem descartar a falha em silêncio).
   */
  public class ContatoEfetivadoException extends Exception {
  }

  /** Mensagem controlada exibida ao vendedor quando o cancelamento falha. */
  public static final String MSG_CONTATO_EFETIVADO_FALHA = 'Não foi possível cancelar as tarefas de contato pendentes deste lead. Nenhuma alteração foi salva — conclua a tarefa novamente.';

  /** Resultado controlado do contato efetivado (CLICKUP-9417). */
  public class ResultadoContatoEfetivado {
    /** Leads marcados como "contato efetivado" agora. */
    public Integer leadsSinalizados = 0;
    /** Tarefas de contato pendentes canceladas. */
    public Integer tarefasCanceladas = 0;
    /** Leads fora do escopo (outro Record Type, convertido, inexistente). */
    public Integer ignorados = 0;
  }

  /**
   * Falha controlada do opt-out (CLICKUP-9418). Mesma semântica atômica da
   * {@link ContatoEfetivadoException}: se a desqualificação / cancelamento não
   * puder ser concluída, a conclusão da Task é desfeita e o vendedor tenta de
   * novo — sem estado inconsistente e sem descartar a falha em silêncio.
   */
  public class OptOutException extends Exception {
  }

  /** Mensagem controlada exibida ao vendedor quando o opt-out falha. */
  public static final String MSG_OPT_OUT_FALHA = 'Não foi possível registrar o opt-out deste lead. Nenhuma alteração foi salva — conclua a tarefa novamente.';

  /** Resultado controlado do opt-out (CLICKUP-9418). */
  public class ResultadoOptOut {
    /** Leads desqualificados por opt-out agora. */
    public Integer leadsDesqualificados = 0;
    /** Tarefas de contato pendentes canceladas. */
    public Integer tarefasCanceladas = 0;
    /** Leads fora do escopo (outro Record Type, convertido, inexistente). */
    public Integer ignorados = 0;
  }

  /** Resultado controlado da reatribuição por falta de contato (CLICKUP-9400). */
  public class ResultadoReatribuicao {
    /** Leads que trocaram de proprietário. */
    public Integer reatribuidos = 0;
    /** Leads com 3 tentativas sem contato mas sem outro vendedor disponível. */
    public Integer semOutroVendedor = 0;
    /** Leads fora do escopo (outro Record Type, convertido, ciclo não iniciado, kill-switch). */
    public Integer ignorados = 0;
    /** Leads não reatribuídos por erro controlado. */
    public Integer comErro = 0;
    public List<String> mensagens = new List<String>();
  }

  @TestVisible
  private static String queueDeveloperName() {
    return String.isBlank(queueDeveloperNameOverride)
      ? QUEUE_DEVELOPER_NAME
      : queueDeveloperNameOverride;
  }

  @TestVisible
  private static String singletonKey() {
    return String.isBlank(singletonKeyOverride)
      ? SINGLETON_KEY
      : singletonKeyOverride;
  }

  // =====================================================================
  //  DISTRIBUIÇÃO
  // =====================================================================

  /**
   * Distribui em round-robin os Leads informados. Bulk-safe: nenhuma consulta
   * ou DML dentro de laço. Transacional: se a gravação dos Leads falhar, o
   * ponteiro não avança (Savepoint/rollback).
   *
   * @param leadIds coleção de IDs de Lead (qualquer Record Type; só os do
   *   Record Type SOL ainda não distribuídos são processados).
   * @return Resultado controlado com as contagens e mensagens seguras.
   */
  public static Resultado distribuir(List<Id> leadIds) {
    Resultado r = new Resultado();
    if (leadIds == null || leadIds.isEmpty()) {
      return r;
    }

    Set<Id> ids = new Set<Id>(leadIds);
    Datetime agora = System.now();

    Savepoint sp = Database.setSavepoint();
    try {
      // (3) trava o singleton: serializa o avanço do ponteiro entre transações.
      SOL_Distribuicao_Estado__c estado = bloquearSingleton();

      // (7) Leads relidos DEPOIS da trava do singleton — assim uma execução
      // concorrente enxerga o status já gravado pela outra e não redistribui.
      // Só não convertidos: um Lead convertido já tem dono final.
      //
      // (CLICKUP-9425) FOR UPDATE também nos LEADS. Sem o lock havia uma janela
      // real: a distribuição lia o Lead ativo, a perda confirmava em OUTRA
      // transação e a distribuição sobrescrevia proprietário/status ou criava a
      // tarefa de 1ª ligação num negócio já perdido. Com o lock, ou a perda
      // commita antes (e a leitura abaixo já a enxerga) ou espera esta
      // transação terminar. ORDEM DOS LOCKS PRESERVADA: singleton primeiro,
      // Leads depois — a mesma de `reatribuirPorFaltaDeContato` e de
      // `SOLPrazoTotalService`, o que evita deadlock entre eles.
      //
      // SOQL recusa `ORDER BY` junto de `FOR UPDATE` ("Explicit ORDER BY not
      // allowed when locking rows"), então a ordenação determinística que a
      // rotação exige — CreatedDate ASC, Id ASC — é aplicada em memória logo
      // abaixo, com exatamente o mesmo critério de antes.
      List<Lead> travados = [
        SELECT
          Id,
          OwnerId,
          CreatedDate,
          RecordType.DeveloperName,
          SOL_Status_Distribuicao__c,
          SOL_Opt_Out__c,
          Status,
          SOL_Motivo_Desqualificacao__c
        FROM Lead
        WHERE Id IN :ids AND IsConverted = false
        FOR UPDATE
      ];
      List<Lead> carregados = ordenarPorCriacao(travados);

      // (8)(13) filtra em memória: só Record Type SOL ainda não Distribuido.
      List<Lead> elegiveis = new List<Lead>();
      Set<Id> encontrados = new Set<Id>();
      for (Lead l : carregados) {
        encontrados.add(l.Id);
        if (l.RecordType.DeveloperName != RECORD_TYPE_DEVELOPER_NAME) {
          r.ignorados++;
          continue;
        }
        if (l.SOL_Status_Distribuicao__c == STATUS_DISTRIBUIDO) {
          r.ignorados++;
          continue;
        }
        // (CLICKUP-9418) opt-out: não distribui nem cria tarefa de contato.
        if (l.SOL_Opt_Out__c == true) {
          r.ignorados++;
          continue;
        }
        // (CLICKUP-9425) REVALIDAÇÃO PÓS-LOCK: negócio já perdido não é
        // redistribuído e não recebe a tarefa de 1ª ligação. Os campos vêm da
        // leitura COM FOR UPDATE acima, então este é o estado confirmado do
        // banco — o bloqueio vale para replay do Flow, para o Batch de
        // reprocessamento (que chama este método com Leads antigos) e para uma
        // perda concorrente que tenha commitado antes do nosso lock.
        if (SOLNegocioPerdidoService.leadPerdido(l)) {
          r.ignorados++;
          continue;
        }
        elegiveis.add(l);
      }
      // Não encontrados aqui = inexistentes OU convertidos: ignorados.
      r.ignorados += (ids.size() - encontrados.size());

      if (elegiveis.isEmpty()) {
        return r;
      }

      Group fila = localizarFilaValida();

      List<User> ativos = new List<User>();
      if (estado.Ativo__c) {
        try {
          ativos = obterMembrosDiretosAtivos(fila.Id);
        } catch (RosterVazioException e) {
          ativos = new List<User>();
        }
      }

      // (11) kill-switch OU (12) sem vendedor ativo -> fallback para a fila.
      if (!estado.Ativo__c || ativos.isEmpty()) {
        for (Lead l : elegiveis) {
          l.OwnerId = fila.Id;
          l.SOL_Status_Distribuicao__c = STATUS_FALLBACK;
          l.SOL_Data_Distribuicao__c = agora;
          l.SOL_Erro_Distribuicao__c = null;
        }
        update elegiveis;
        r.emFallback = elegiveis.size();
        // ponteiro NÃO é tocado no fallback.
        return r;
      }

      // (4)(5)(6) ponto de partida na rotação.
      Integer n = ativos.size();
      Integer inicio = 0;
      if (estado.Ultimo_Usuario__c != null) {
        Integer k = indiceDe(ativos, estado.Ultimo_Usuario__c);
        inicio = (k >= 0) ? Math.mod(k + 1, n) : 0;
      }

      // (9) atribui em memória; um único update depois do laço.
      for (Integer i = 0; i < elegiveis.size(); i++) {
        Lead l = elegiveis[i];
        l.OwnerId = ativos[Math.mod(inicio + i, n)].Id;
        l.SOL_Status_Distribuicao__c = STATUS_DISTRIBUIDO;
        l.SOL_Data_Distribuicao__c = agora;
        l.SOL_Erro_Distribuicao__c = null;
        // CLICKUP-9400: abre o ciclo de contato do vendedor que recebeu o Lead.
        l.SOL_Data_Inicio_Ciclo_Contato__c = agora;
        l.SOL_Status_Reatribuicao__c = REATRIB_EM_ACOMPANHAMENTO;
      }
      update elegiveis;

      // (CLICKUP-9396) Task "1ª Ligação" — uma por atribuição bem-sucedida.
      // (CLICKUP-9434) É o DIA 1 da cadência; o ciclo gravado na tarefa é o que
      // acabou de ser aberto acima, então a chave Lead+ciclo+canal+dia é inédita
      // por construção e a distribuição não pode duplicar a ligação.
      // Dentro do try/Savepoint: se a criação falhar, o rollback desfaz o Owner
      // e o ponteiro NÃO avança (nenhuma inconsistência).
      List<Task> tarefasLigacao = montarTasksPrimeiraLigacao(elegiveis, agora);
      if (!tarefasLigacao.isEmpty()) {
        insert tarefasLigacao;
      }

      // (10) ponteiro/data/total só depois da atribuição bem-sucedida.
      User ultimo = ativos[Math.mod(inicio + elegiveis.size() - 1, n)];
      estado.Ultimo_Usuario__c = ultimo.Id;
      estado.Data_Ultima_Distribuicao__c = agora;
      estado.Total_Distribuido__c =
        (estado.Total_Distribuido__c == null ? 0 : estado.Total_Distribuido__c) +
        elegiveis.size();
      update estado;

      r.distribuidos = elegiveis.size();
      return r;
    } catch (DistribuicaoException e) {
      // Configuração/estado indisponível (singleton, fila) — rollback total.
      Database.rollback(sp);
      marcarErro(ids, MSG_CONFIG, agora, r);
      return r;
    } catch (Exception e) {
      // Falha de DML ou inesperada — rollback total: o ponteiro não avança.
      Database.rollback(sp);
      System.debug(
        LoggingLevel.ERROR,
        'SOLDistribuicaoService.distribuir: ' +
          e.getTypeName() +
          ': ' +
          e.getMessage() +
          '\n' +
          e.getStackTraceString()
      );
      marcarErro(ids, MSG_ERRO_GENERICO, agora, r);
      return r;
    }
  }

  /**
   * Tratamento de erro — best-effort, executado APÓS o rollback.
   *
   * Tenta localizar a Fila_Leads_SOL por DeveloperName (não depende de a
   * Assignment Rule ter rodado). Se a fila estiver disponível, deixa o Lead
   * nela (OwnerId da fila) com status Erro, data e mensagem controlada. Se a
   * fila estiver indisponível, grava só os campos possíveis. Nunca relança e
   * nunca toca Leads de outro Record Type.
   *
   * (CLICKUP-9425) Relê os Leads com FOR UPDATE e projeta Status,
   * SOL_Motivo_Desqualificacao__c e SOL_Opt_Out__c: negócio PERDIDO e Lead em
   * OPT-OUT ficam de fora — não têm proprietário, status, data nem mensagem de
   * erro alterados, e não entram na contagem de `comErro`.
   */
  private static void marcarErro(
    Set<Id> ids,
    String mensagem,
    Datetime agora,
    Resultado r
  ) {
    Id filaId = null;
    try {
      Group fila = filaSemLancar();
      if (fila != null) {
        filaId = fila.Id;
      }
    } catch (Exception ignorado) {
      // best-effort: seguir sem a fila.
    }

    // (CLICKUP-9425) Releitura COM FOR UPDATE e com os campos da perda e do
    // opt-out projetados: este método roda DEPOIS do rollback, então precisa do
    // estado atual do banco, não do que a transação abortada tinha em memória.
    // Sem o lock, uma perda concorrente poderia commitar entre esta leitura e o
    // update abaixo, e o Lead perdido acabaria movido para a fila com status de
    // erro.
    List<Lead> candidatos = [
      SELECT Id, Status, SOL_Motivo_Desqualificacao__c, SOL_Opt_Out__c
      FROM Lead
      WHERE
        Id IN :ids
        AND RecordType.DeveloperName = :RECORD_TYPE_DEVELOPER_NAME
        AND IsConverted = false
        AND (SOL_Status_Distribuicao__c = null
        OR SOL_Status_Distribuicao__c != :STATUS_DISTRIBUIDO)
      FOR UPDATE
    ];

    List<Lead> paraErro = new List<Lead>();
    for (Lead l : candidatos) {
      // (CLICKUP-9425) negócio já perdido: NÃO altera proprietário, status,
      // data nem mensagem de erro da distribuição. Um Lead perdido não volta
      // para a fila e não é rotulado como falha de distribuição.
      if (SOLNegocioPerdidoService.leadPerdido(l)) {
        continue;
      }
      // (CLICKUP-9418) mesmo isolamento do opt-out que a distribuição aplica:
      // quem pediu para não ser contatado também não é devolvido à fila.
      if (l.SOL_Opt_Out__c == true) {
        continue;
      }
      if (filaId != null) {
        l.OwnerId = filaId;
      }
      l.SOL_Status_Distribuicao__c = STATUS_ERRO;
      l.SOL_Erro_Distribuicao__c = mensagem;
      l.SOL_Data_Distribuicao__c = agora;
      paraErro.add(l);
    }
    if (!paraErro.isEmpty()) {
      // best-effort: marcar o erro nunca deve relançar nem bloquear a criação.
      Database.update(paraErro, false);
    }
    r.comErro = paraErro.size();
    r.mensagens.add(mensagem);
  }

  /**
   * Ordem determinística da rotação: CreatedDate ASC, Id ASC — exatamente o
   * `ORDER BY` que a consulta usava antes do CLICKUP-9425. Passou para memória
   * porque SOQL não aceita `ORDER BY` junto de `FOR UPDATE`. Função pura.
   */
  private static List<Lead> ordenarPorCriacao(List<Lead> entrada) {
    List<LeadPorCriacao> envelopes = new List<LeadPorCriacao>();
    for (Lead l : entrada) {
      envelopes.add(new LeadPorCriacao(l));
    }
    envelopes.sort();
    List<Lead> saida = new List<Lead>();
    for (LeadPorCriacao e : envelopes) {
      saida.add(e.registro);
    }
    return saida;
  }

  /** Envelope só para ordenar Leads por CreatedDate e, no empate, por Id. */
  private class LeadPorCriacao implements Comparable {
    private final Lead registro;

    private LeadPorCriacao(Lead registro) {
      this.registro = registro;
    }

    public Integer compareTo(Object outro) {
      Lead b = ((LeadPorCriacao) outro).registro;
      if (registro.CreatedDate != b.CreatedDate) {
        return registro.CreatedDate < b.CreatedDate ? -1 : 1;
      }
      return String.valueOf(registro.Id).compareTo(String.valueOf(b.Id));
    }
  }

  /**
   * Índice de `alvo` no roster ordenado, ou -1. Público para que os serviços de
   * reatribuição (CLICKUP-9400 / CLICKUP-9424) REUTILIZEM a rotação em vez de
   * duplicá-la. Função pura: sem SOQL, sem DML, sem estado.
   */
  public static Integer indiceDe(List<User> lista, Id alvo) {
    for (Integer i = 0; i < lista.size(); i++) {
      if (lista[i].Id == alvo) {
        return i;
      }
    }
    return -1;
  }

  // =====================================================================
  //  REATRIBUIÇÃO POR FALTA DE CONTATO (CLICKUP-9400)
  // =====================================================================

  /**
   * Reatribui, em round-robin, os Leads do Record Type SOL cujo ciclo de contato
   * do vendedor atual acumulou {@link #TENTATIVAS_PARA_REATRIBUIR} Tasks
   * concluídas com resultado CONTABILIZÁVEL — desde que nenhuma Task do ciclo
   * tenha "Atendeu", que é o único resultado que bloqueia a troca do ciclo.
   *
   * (CLICKUP-9437) Contabilizam três resultados: "Atendeu_Sem_Conclusao" (houve
   * conversa, nada avançou), "Não atendeu" e "Não foi possível ligar". O valor
   * novo entra em `RESULTADOS_NEGATIVOS` e em `RESULTADOS_CONSIDERADOS`; o
   * porquê dos dois está documentado na declaração daquele segundo Set — sem
   * ele, o ciclo reiniciado não excluiria a tarefa que disparou a troca e o
   * mesmo Lead seria reatribuído em cascata.
   *
   * Bulk-safe: nenhuma consulta ou DML dentro de laço. Transacional: Savepoint /
   * rollback. Usa o MESMO singleton, lock (FOR UPDATE), fila, roster e ponteiro
   * global da distribuição inicial (CLICKUP-9394) — serializa com ela e evita
   * duas reatribuições concorrentes do mesmo Lead (a segunda transação relê o
   * ciclo já reiniciado e não encontra 3 tentativas).
   *
   * NÃO reaproveita a proteção que impede redistribuir Leads já "Distribuido":
   * todo alvo aqui já está distribuído.
   *
   * @param leadIds Ids de Lead candidatos (qualquer origem; filtrados aqui).
   * @return contagens controladas.
   */
  public static ResultadoReatribuicao reatribuirPorFaltaDeContato(
    List<Id> leadIds
  ) {
    ResultadoReatribuicao r = new ResultadoReatribuicao();
    if (leadIds == null || leadIds.isEmpty()) {
      return r;
    }

    Set<Id> ids = new Set<Id>(leadIds);
    Datetime agora = System.now();

    Savepoint sp = Database.setSavepoint();
    try {
      // Mesmo lock da distribuição inicial: serializa o avanço do ponteiro e a
      // própria reatribuição entre transações concorrentes.
      SOL_Distribuicao_Estado__c estado = bloquearSingleton();

      // (CLICKUP-9425) FOR UPDATE: este caminho roda por Flow e por varredura,
      // sobre Leads antigos, e concorre com a desqualificação por perda — que
      // também trava o Lead. O lock serializa os dois e garante que o estado
      // lido abaixo é o atual.
      List<Lead> carregados = [
        SELECT
          Id,
          OwnerId,
          RecordType.DeveloperName,
          SOL_Data_Inicio_Ciclo_Contato__c,
          SOL_Quantidade_Reatribuicoes__c,
          SOL_Opt_Out__c,
          Status,
          SOL_Motivo_Desqualificacao__c
        FROM Lead
        WHERE Id IN :ids AND IsConverted = false
        FOR UPDATE
      ];

      // Só Record Type SOL e com ciclo de contato já iniciado (distribuição
      // inicial concluída). Leads convertidos/inexistentes: ignorados.
      Map<Id, Lead> candidatos = new Map<Id, Lead>();
      Set<Id> encontrados = new Set<Id>();
      for (Lead l : carregados) {
        encontrados.add(l.Id);
        if (l.RecordType.DeveloperName != RECORD_TYPE_DEVELOPER_NAME) {
          r.ignorados++;
          continue;
        }
        if (l.SOL_Data_Inicio_Ciclo_Contato__c == null) {
          r.ignorados++;
          continue;
        }
        // (CLICKUP-9418) opt-out: Lead desqualificado não é reatribuído e não
        // recebe nova tarefa de contato.
        if (l.SOL_Opt_Out__c == true) {
          r.ignorados++;
          continue;
        }
        // (CLICKUP-9425) negócio já perdido: não reatribui e não cria tarefa.
        if (SOLNegocioPerdidoService.leadPerdido(l)) {
          r.ignorados++;
          continue;
        }
        candidatos.put(l.Id, l);
      }
      r.ignorados += (ids.size() - encontrados.size());

      if (candidatos.isEmpty()) {
        return r;
      }

      // Kill-switch desligado: a reatribuição também para.
      if (!estado.Ativo__c) {
        r.ignorados += candidatos.size();
        return r;
      }

      // Menor início de ciclo entre os candidatos: reduz as linhas de Task lidas.
      Datetime corteMinimo = null;
      for (Lead l : candidatos.values()) {
        if (
          corteMinimo == null ||
          l.SOL_Data_Inicio_Ciclo_Contato__c < corteMinimo
        ) {
          corteMinimo = l.SOL_Data_Inicio_Ciclo_Contato__c;
        }
      }

      // (contagem) Tasks CONCLUÍDAS, ligadas ao Lead por WhoId, com resultado de
      // contato preenchido, concluídas a partir do corte. Uma única consulta; o
      // corte por Lead é aplicado em memória (varia por Lead). CLICKUP-9396:
      // "Atendeu" = contato efetivado (bloqueia); "Não atendeu" e "Não foi
      // possível ligar" contam como tentativa negativa. CLICKUP-9437:
      // "Atendeu_Sem_Conclusao" também conta — houve conversa, mas nada avançou
      // — e continua NÃO bloqueando, porque o bloqueio é exclusivo de "Atendeu".
      Map<Id, Integer> negativosNoCiclo = new Map<Id, Integer>();
      Set<Id> teveAtendimentoNoCiclo = new Set<Id>();
      // Última conclusão contada por Lead: base para reiniciar o ciclo de forma
      // que as Tasks que dispararam a troca não voltem a contar.
      Map<Id, Datetime> ultimaConclusaoNoCiclo = new Map<Id, Datetime>();
      for (Task t : [
        SELECT WhoId, SOL_Resultado_Contato__c, CompletedDateTime
        FROM Task
        WHERE
          WhoId IN :candidatos.keySet()
          AND IsClosed = true
          AND SOL_Resultado_Contato__c IN :RESULTADOS_CONSIDERADOS
          AND CompletedDateTime >= :corteMinimo
      ]) {
        Lead l = candidatos.get(t.WhoId);
        if (
          l == null ||
          t.CompletedDateTime == null ||
          t.CompletedDateTime < l.SOL_Data_Inicio_Ciclo_Contato__c
        ) {
          continue;
        }
        if (
          !ultimaConclusaoNoCiclo.containsKey(t.WhoId) ||
          t.CompletedDateTime > ultimaConclusaoNoCiclo.get(t.WhoId)
        ) {
          ultimaConclusaoNoCiclo.put(t.WhoId, t.CompletedDateTime);
        }
        // Só "Atendeu" bloqueia a troca. "Atendeu_Sem_Conclusao" cai no `else`
        // e é contado como tentativa — é exatamente essa a diferença entre os
        // dois (CLICKUP-9437).
        if (t.SOL_Resultado_Contato__c == RESULTADO_ATENDEU) {
          teveAtendimentoNoCiclo.add(t.WhoId);
        } else if (RESULTADOS_NEGATIVOS.contains(t.SOL_Resultado_Contato__c)) {
          Integer c = negativosNoCiclo.containsKey(t.WhoId)
            ? negativosNoCiclo.get(t.WhoId)
            : 0;
          negativosNoCiclo.put(t.WhoId, c + 1);
        }
      }

      List<Lead> paraReatribuir = new List<Lead>();
      for (Lead l : candidatos.values()) {
        if (teveAtendimentoNoCiclo.contains(l.Id)) {
          // Contato efetivado ("Atendeu") no ciclo: não reatribui.
          continue;
        }
        Integer qtd = negativosNoCiclo.containsKey(l.Id)
          ? negativosNoCiclo.get(l.Id)
          : 0;
        if (qtd >= TENTATIVAS_PARA_REATRIBUIR) {
          paraReatribuir.add(l);
        }
      }

      if (paraReatribuir.isEmpty()) {
        return r;
      }

      // Roster: mesmos membros diretos ativos da Fila_Leads_SOL.
      Group fila = localizarFilaValida();
      List<User> ativos;
      try {
        ativos = obterMembrosDiretosAtivos(fila.Id);
      } catch (RosterVazioException e) {
        ativos = new List<User>();
      }
      Integer n = ativos.size();

      // Ponto de partida: o próximo após o ponteiro global (User.Id ASC).
      Integer cursor = 0;
      if (n > 0 && estado.Ultimo_Usuario__c != null) {
        Integer k = indiceDe(ativos, estado.Ultimo_Usuario__c);
        cursor = (k >= 0) ? Math.mod(k + 1, n) : 0;
      }

      Id ponteiroNovo = estado.Ultimo_Usuario__c;
      List<Lead> leadsAlterados = new List<Lead>();
      List<Lead> reatribuidos = new List<Lead>();

      for (Lead l : paraReatribuir) {
        Id escolhido = proximoVendedorExcluindo(ativos, cursor, l.OwnerId);

        // Novo início de ciclo: logo após a última Task contada (e nunca no
        // passado). Garante que as Tasks que dispararam a avaliação não voltem
        // a contar — mesmo quando System.now() é constante (contexto de teste)
        // ou a avaliação roda de novo na mesma transação.
        Datetime novoCiclo = agora;
        if (ultimaConclusaoNoCiclo.containsKey(l.Id)) {
          Datetime aposUltima = Datetime.newInstance(
            ultimaConclusaoNoCiclo.get(l.Id).getTime() + 1000
          );
          if (aposUltima > novoCiclo) {
            novoCiclo = aposUltima;
          }
        }

        if (escolhido == null) {
          // Só há (no máximo) o próprio proprietário atual ativo: mantém o Lead.
          l.SOL_Status_Reatribuicao__c = REATRIB_SEM_OUTRO_VENDEDOR;
          l.SOL_Motivo_Ultima_Reatribuicao__c = MOTIVO_SEM_OUTRO_VENDEDOR;
          // Reinicia o ciclo mesmo aqui: evita reavaliar a cada nova Task
          // enquanto não houver outro vendedor.
          l.SOL_Data_Inicio_Ciclo_Contato__c = novoCiclo;
          leadsAlterados.add(l);
          r.semOutroVendedor++;
          continue;
        }

        // Consome o ponteiro: avança para depois do vendedor escolhido.
        Integer ie = indiceDe(ativos, escolhido);
        cursor = Math.mod(ie + 1, n);

        l.OwnerId = escolhido;
        l.SOL_Quantidade_Reatribuicoes__c =
          (l.SOL_Quantidade_Reatribuicoes__c == null
            ? 0
            : l.SOL_Quantidade_Reatribuicoes__c) + 1;
        l.SOL_Data_Ultima_Reatribuicao__c = agora;
        l.SOL_Motivo_Ultima_Reatribuicao__c = MOTIVO_REATRIBUICAO;
        l.SOL_Status_Reatribuicao__c = REATRIB_REATRIBUIDO;
        // Reinicia o ciclo: as Tasks anteriores ficam no histórico, fora da
        // nova contagem.
        l.SOL_Data_Inicio_Ciclo_Contato__c = novoCiclo;
        leadsAlterados.add(l);
        ponteiroNovo = escolhido;
        r.reatribuidos++;
        reatribuidos.add(l);
      }

      if (!leadsAlterados.isEmpty()) {
        update leadsAlterados;
      }
      // (CLICKUP-9396) Task "1ª Ligação" — uma por reatribuição efetivada.
      // (CLICKUP-9434) É o DIA 1 do NOVO ciclo: cada Lead leva consigo o
      // `novoCiclo` gravado acima, então a tarefa nasce com o ciclo correto e
      // não colide com as ligações do ciclo do vendedor anterior.
      // Dentro do try/Savepoint: falha aqui faz rollback e o ponteiro não avança.
      List<Task> tarefasNovas = montarTasksPrimeiraLigacao(reatribuidos, agora);
      if (!tarefasNovas.isEmpty()) {
        insert tarefasNovas;
      }
      if (ponteiroNovo != estado.Ultimo_Usuario__c) {
        estado.Ultimo_Usuario__c = ponteiroNovo;
        estado.Data_Ultima_Distribuicao__c = agora;
        update estado;
      }

      return r;
    } catch (DistribuicaoException e) {
      Database.rollback(sp);
      r.comErro = ids.size();
      r.mensagens.add(MSG_CONFIG);
      return r;
    } catch (Exception e) {
      Database.rollback(sp);
      System.debug(
        LoggingLevel.ERROR,
        'SOLDistribuicaoService.reatribuirPorFaltaDeContato: ' +
          e.getTypeName() +
          ': ' +
          e.getMessage() +
          '\n' +
          e.getStackTraceString()
      );
      r.comErro = ids.size();
      r.mensagens.add(MSG_ERRO_GENERICO);
      return r;
    }
  }

  /**
   * Próximo vendedor na rotação a partir de `cursor`, pulando `donoAtual`.
   * Retorna null quando não há nenhum vendedor ativo diferente do dono atual
   * (roster vazio, ou o dono atual é o único ativo).
   *
   * Público para que os serviços de reatribuição (CLICKUP-9400 / CLICKUP-9424)
   * REUTILIZEM esta seleção em vez de duplicá-la. Função pura: sem SOQL, sem
   * DML, sem estado.
   */
  public static Id proximoVendedorExcluindo(
    List<User> ativos,
    Integer cursor,
    Id donoAtual
  ) {
    Integer n = ativos.size();
    for (Integer passo = 0; passo < n; passo++) {
      User u = ativos[Math.mod(cursor + passo, n)];
      if (u.Id != donoAtual) {
        return u.Id;
      }
    }
    return null;
  }

  // =====================================================================
  //  CONTATO EFETIVADO — CANCELAMENTO DE TAREFAS PENDENTES (CLICKUP-9417)
  // =====================================================================

  /**
   * Sinaliza o contato efetivado nos Leads informados e cancela as tarefas de
   * contato SOL ainda PENDENTES desses Leads.
   *
   * Disparado quando o vendedor conclui uma tarefa de contato
   * (SOL_Tipo_Tarefa__c = 'Contato') com resultado "Atendeu" — a qualquer
   * momento, sem bloqueio por horário/dia (cliente pode retornar no fim de
   * semana).
   *
   * Bulk-safe: nenhuma consulta ou DML dentro de laço. Concorrência: os Leads e
   * as tarefas pendentes são travados com FOR UPDATE, o que serializa dois
   * "Atendeu" simultâneos do mesmo Lead. Idempotente: um 2º disparo não
   * encontra mais tarefas pendentes e não reprocessa o flag. Recursão: as
   * tarefas ficam com Status "Cancelada" e sem resultado "Atendeu" — o Flow
   * SOL_Contato_Efetivado não volta a disparar.
   *
   * ATÔMICO: em qualquer falha, o Savepoint desfaz o que foi alterado e o
   * método RELANÇA {@link ContatoEfetivadoException}. Propagada pelo Invocable,
   * ela aborta a transação inteira (incl. a conclusão da Task), evitando estado
   * inconsistente. A falha nunca é descartada em silêncio.
   *
   * NÃO altera tarefas já concluídas (Status "Completed"): o histórico de
   * tentativas anteriores permanece intacto. NÃO altera o status do funil do
   * Lead nem cria tarefas.
   *
   * @param leadIds Ids de Lead (qualquer origem; filtrados aqui para RT SOL).
   * @return contagens controladas.
   * @throws ContatoEfetivadoException falha ao sinalizar/cancelar (transação
   *   deve ser abortada).
   */
  public static ResultadoContatoEfetivado registrarContatoEfetivado(
    List<Id> leadIds
  ) {
    ResultadoContatoEfetivado r = new ResultadoContatoEfetivado();
    if (leadIds == null || leadIds.isEmpty()) {
      return r;
    }

    Set<Id> ids = new Set<Id>(leadIds);
    Datetime agora = System.now();

    Savepoint sp = null;
    try {
      sp = Database.setSavepoint();
      // Trava os Leads: serializa dois "Atendeu" concorrentes do mesmo Lead.
      List<Lead> carregados = [
        SELECT
          Id,
          RecordType.DeveloperName,
          SOL_Contato_Efetivado__c,
          SOL_Data_Contato_Efetivado__c,
          Status,
          SOL_Motivo_Desqualificacao__c,
          SOL_Opt_Out__c
        FROM Lead
        WHERE Id IN :ids AND IsConverted = false
        FOR UPDATE
      ];

      List<Lead> leadsParaSinalizar = new List<Lead>();
      Set<Id> leadsSOL = new Set<Id>();
      Set<Id> encontrados = new Set<Id>();
      for (Lead l : carregados) {
        encontrados.add(l.Id);
        if (l.RecordType.DeveloperName != RECORD_TYPE_DEVELOPER_NAME) {
          r.ignorados++;
          continue;
        }
        // (CLICKUP-9425) negócio já perdido: não sinaliza contato efetivado nem
        // mexe nas tarefas. SOL_Data_Contato_Efetivado__c alimenta o prazo de 30
        // dias úteis (CLICKUP-9424) e não pode nascer depois da perda.
        if (SOLNegocioPerdidoService.leadPerdido(l)) {
          r.ignorados++;
          continue;
        }
        leadsSOL.add(l.Id);
        // Idempotência: só grava o flag/data se ainda não sinalizado.
        if (l.SOL_Contato_Efetivado__c != true) {
          l.SOL_Contato_Efetivado__c = true;
          l.SOL_Data_Contato_Efetivado__c = agora;
          leadsParaSinalizar.add(l);
        }
      }
      r.ignorados += (ids.size() - encontrados.size());

      if (leadsSOL.isEmpty()) {
        return r;
      }

      // Tarefas de contato AINDA PENDENTES (IsClosed = false) dos Leads SOL. A
      // tarefa que efetivou o contato já está "Completed" e não entra aqui;
      // tarefas já concluídas não são tocadas.
      List<Task> pendentes = [
        SELECT Id
        FROM Task
        WHERE
          WhoId IN :leadsSOL
          AND SOL_Tipo_Tarefa__c = :TIPO_TAREFA_CONTATO
          AND IsClosed = false
        FOR UPDATE
      ];
      for (Task t : pendentes) {
        t.Status = TASK_STATUS_CANCELADA;
        t.SOL_Motivo_Cancelamento__c = MOTIVO_CANCELAMENTO_CONTATO_EFETIVADO;
      }

      if (!leadsParaSinalizar.isEmpty()) {
        update leadsParaSinalizar;
      }
      if (!pendentes.isEmpty()) {
        update pendentes;
      }

      r.leadsSinalizados = leadsParaSinalizar.size();
      r.tarefasCanceladas = pendentes.size();
      return r;
    } catch (Exception e) {
      // Operação ATÔMICA: desfaz o que este método alterou e RELANÇA uma falha
      // controlada. Quem chama (Flow/Invocable) propaga a exceção, o que
      // desfaz também a conclusão da Task que disparou tudo — nada fica em
      // estado inconsistente e a falha não é descartada em silêncio.
      if (sp != null) {
        Database.rollback(sp);
      }
      System.debug(
        LoggingLevel.ERROR,
        'SOLDistribuicaoService.registrarContatoEfetivado: ' +
          e.getTypeName() +
          ': ' +
          e.getMessage() +
          '\n' +
          e.getStackTraceString()
      );
      throw new ContatoEfetivadoException(MSG_CONTATO_EFETIVADO_FALHA);
    }
  }

  // =====================================================================
  //  OPT-OUT — LEAD PEDE PARA NÃO SER MAIS CONTATADO (CLICKUP-9418)
  // =====================================================================

  /**
   * Registra o opt-out dos Leads informados: marca o flag e a data, desqualifica
   * o Lead (Status "Desqualificado", motivo "Opt-out") e cancela as tarefas de
   * contato SOL ainda PENDENTES. A partir daí, `distribuir()` e
   * `reatribuirPorFaltaDeContato()` ignoram o Lead — nenhuma nova tarefa de
   * contato é criada.
   *
   * Disparado quando o vendedor conclui uma tarefa de contato
   * (SOL_Tipo_Tarefa__c = 'Contato') com resultado "Opt-out", a qualquer
   * momento da cadência, sem bloqueio por horário/dia ou prazo.
   *
   * Bulk-safe: nenhuma consulta ou DML dentro de laço. Concorrência: Leads e
   * tarefas pendentes travados com FOR UPDATE. Idempotente: um 2º disparo não
   * encontra Lead sem opt-out nem tarefa pendente. Recursão: as tarefas ficam
   * "Cancelada" (sem resultado "Opt-out") e o Lead fica com SOL_Opt_Out__c =
   * true — o Flow SOL_Opt_Out não volta a disparar.
   *
   * ATÔMICO: em qualquer falha, o Savepoint desfaz tudo e o método RELANÇA
   * {@link OptOutException}; propagada pelo Invocable, aborta a transação
   * inteira (incl. a conclusão da Task). A falha nunca é descartada em silêncio.
   *
   * NÃO altera tarefas já concluídas (o histórico permanece intacto). NÃO
   * encerra tarefas que não sejam de contato — o encerramento geral por perda
   * do negócio é escopo do CLICKUP-9425.
   *
   * @param leadIds Ids de Lead (qualquer origem; filtrados aqui para RT SOL).
   * @return contagens controladas.
   * @throws OptOutException falha ao desqualificar/cancelar (transação deve ser
   *   abortada).
   */
  public static ResultadoOptOut registrarOptOut(List<Id> leadIds) {
    ResultadoOptOut r = new ResultadoOptOut();
    if (leadIds == null || leadIds.isEmpty()) {
      return r;
    }

    Set<Id> ids = new Set<Id>(leadIds);
    Datetime agora = System.now();

    Savepoint sp = null;
    try {
      sp = Database.setSavepoint();
      // Trava os Leads: serializa dois opt-outs concorrentes do mesmo Lead.
      List<Lead> carregados = [
        SELECT
          Id,
          RecordType.DeveloperName,
          SOL_Opt_Out__c,
          Status,
          SOL_Motivo_Desqualificacao__c
        FROM Lead
        WHERE Id IN :ids AND IsConverted = false
        FOR UPDATE
      ];

      List<Lead> leadsParaDesqualificar = new List<Lead>();
      Set<Id> leadsSOL = new Set<Id>();
      Set<Id> encontrados = new Set<Id>();
      for (Lead l : carregados) {
        encontrados.add(l.Id);
        if (l.RecordType.DeveloperName != RECORD_TYPE_DEVELOPER_NAME) {
          r.ignorados++;
          continue;
        }
        // (CLICKUP-9425) o Lead já foi perdido como negócio: o opt-out NÃO
        // sobrescreve esse registro (motivo "Negócio perdido" seria trocado por
        // "Opt-out") e não há tarefa aberta para cancelar — o encerramento por
        // perda já fechou todas. Os dois fluxos permanecem isolados.
        if (SOLNegocioPerdidoService.leadPerdido(l)) {
          r.ignorados++;
          continue;
        }
        leadsSOL.add(l.Id);
        // Idempotência: só desqualifica se ainda não estava em opt-out.
        if (l.SOL_Opt_Out__c != true) {
          l.SOL_Opt_Out__c = true;
          l.SOL_Data_Opt_Out__c = agora;
          l.Status = LEAD_STATUS_DESQUALIFICADO;
          l.SOL_Motivo_Desqualificacao__c = MOTIVO_DESQUALIFICACAO_OPT_OUT;
          leadsParaDesqualificar.add(l);
        }
      }
      r.ignorados += (ids.size() - encontrados.size());

      if (leadsSOL.isEmpty()) {
        return r;
      }

      // Tarefas de contato AINDA PENDENTES dos Leads SOL. A que registrou o
      // opt-out já está "Completed" e não entra aqui; concluídas não são tocadas.
      List<Task> pendentes = [
        SELECT Id
        FROM Task
        WHERE
          WhoId IN :leadsSOL
          AND SOL_Tipo_Tarefa__c = :TIPO_TAREFA_CONTATO
          AND IsClosed = false
        FOR UPDATE
      ];
      for (Task t : pendentes) {
        t.Status = TASK_STATUS_CANCELADA;
        t.SOL_Motivo_Cancelamento__c = MOTIVO_CANCELAMENTO_OPT_OUT;
      }

      if (!leadsParaDesqualificar.isEmpty()) {
        update leadsParaDesqualificar;
      }
      if (!pendentes.isEmpty()) {
        update pendentes;
      }

      r.leadsDesqualificados = leadsParaDesqualificar.size();
      r.tarefasCanceladas = pendentes.size();
      return r;
    } catch (Exception e) {
      if (sp != null) {
        Database.rollback(sp);
      }
      System.debug(
        LoggingLevel.ERROR,
        'SOLDistribuicaoService.registrarOptOut: ' +
          e.getTypeName() +
          ': ' +
          e.getMessage() +
          '\n' +
          e.getStackTraceString()
      );
      throw new OptOutException(MSG_OPT_OUT_FALHA);
    }
  }

  // =====================================================================
  //  TASK "1ª LIGAÇÃO" — CRIAÇÃO CENTRALIZADA (CLICKUP-9396)
  // =====================================================================

  /**
   * Monta, em bulk, a Task "1ª Ligação" para cada Lead recém-atribuído.
   * Reutilizada pela distribuição inicial (incl. reprocessamento que distribui)
   * e pela reatribuição por falta de contato. O chamador insere as Tasks dentro
   * da mesma transação/Savepoint do serviço.
   *
   * (CLICKUP-9434) A montagem em si vive agora em `SOLCadenciaContatoService`:
   * a "1ª Ligação" é o DIA 1 da cadência de contato e sai de lá já classificada
   * como canal Ligação, dia 1 e ciclo do vendedor. O prazo continua sendo de 5
   * minutos ÚTEIS após `atribuicao`. Este método permanece como o ÚNICO ponto
   * de criação no caminho da distribuição — não há automação concorrente.
   *
   * Cada Lead de `atribuidos` já traz, em memória, o `OwnerId` e o
   * `SOL_Data_Inicio_Ciclo_Contato__c` do ciclo que acabou de ser aberto (na
   * reatribuição o ciclo não é necessariamente `atribuicao`).
   *
   * @param atribuidos Leads que receberam dono nesta transação
   * @param atribuicao instante da atribuição/reatribuição
   */
  @TestVisible
  private static List<Task> montarTasksPrimeiraLigacao(
    List<Lead> atribuidos,
    Datetime atribuicao
  ) {
    return SOLCadenciaContatoService.montarPrimeirasLigacoes(
      atribuidos,
      atribuicao
    );
  }

  // =====================================================================
  //  LEITURAS AUXILIARES (sem lock) — usadas pela varredura (ETAPA 6)
  // =====================================================================

  /** Lê o singleton sem FOR UPDATE, ou null se não existir. */
  public static SOL_Distribuicao_Estado__c lerEstado() {
    List<SOL_Distribuicao_Estado__c> e = [
      SELECT
        Id,
        Chave__c,
        Ativo__c,
        Inicio_Vigencia__c,
        Ultimo_Usuario__c,
        Total_Distribuido__c
      FROM SOL_Distribuicao_Estado__c
      WHERE Chave__c = :singletonKey()
      LIMIT 1
    ];
    return e.isEmpty() ? null : e[0];
  }

  /** true se a fila existe, aceita Lead e tem ao menos um usuário direto ativo. */
  public static Boolean haVendedorDiretoAtivo() {
    Group fila = filaSemLancar();
    if (fila == null) {
      return false;
    }
    try {
      return !obterMembrosDiretosAtivos(fila.Id).isEmpty();
    } catch (RosterVazioException e) {
      return false;
    }
  }

  // =====================================================================
  //  FUNDAÇÃO (ETAPA 3 / 3.1)
  // =====================================================================

  /**
   * Localiza a Group da fila habilitada para Lead, ou null se não existir /
   * não aceitar Lead. Não lança.
   */
  @TestVisible
  private static Group filaSemLancar() {
    List<Group> filas = [
      SELECT
        Id,
        DeveloperName,
        (SELECT Id FROM QueueSobjects WHERE SobjectType = 'Lead')
      FROM Group
      WHERE Type = 'Queue' AND DeveloperName = :queueDeveloperName()
      LIMIT 1
    ];
    if (filas.isEmpty() || filas[0].QueueSobjects.isEmpty()) {
      return null;
    }
    return filas[0];
  }

  /**
   * Localiza a fila e confirma que é uma fila habilitada para Lead.
   *
   * @return o Group da fila (Type = 'Queue').
   * @throws FilaInexistenteException não há Group Queue com esse DeveloperName.
   * @throws FilaInvalidaException a fila existe mas não aceita Lead.
   */
  public static Group localizarFilaValida() {
    String devName = queueDeveloperName();

    List<Group> filas = [
      SELECT
        Id,
        DeveloperName,
        (SELECT Id FROM QueueSobjects WHERE SobjectType = 'Lead')
      FROM Group
      WHERE Type = 'Queue' AND DeveloperName = :devName
      LIMIT 1
    ];

    if (filas.isEmpty()) {
      throw new FilaInexistenteException(
        'Fila "' +
          devName +
          '" não encontrada: nenhum Group do tipo Queue com esse DeveloperName.'
      );
    }
    if (filas[0].QueueSobjects.isEmpty()) {
      throw new FilaInvalidaException(
        'Fila "' +
          devName +
          '" existe, mas não está habilitada para o objeto Lead.'
      );
    }
    return filas[0];
  }

  /**
   * Participantes do round-robin: usuários DIRETOS da fila, ATIVOS, ordenados
   * de forma determinística por User.Id ASC.
   *
   * @throws FilaInexistenteException / FilaInvalidaException via localizarFilaValida.
   * @throws RosterVazioException nenhum usuário direto ativo na fila.
   */
  public static List<User> obterMembrosDiretosAtivos() {
    return obterMembrosDiretosAtivos(localizarFilaValida().Id);
  }

  /** Sobrecarga com a fila já resolvida. */
  public static List<User> obterMembrosDiretosAtivos(Id filaId) {
    Set<Id> idsUsuarios = new Set<Id>();
    for (GroupMember membro : [
      SELECT UserOrGroupId
      FROM GroupMember
      WHERE GroupId = :filaId
    ]) {
      // Só membro DIRETO do tipo User. Grupos públicos, papéis, "papéis e
      // subordinados" e filas aninhadas têm Id 00G e ficam de fora.
      if (membro.UserOrGroupId.getSObjectType() == User.SObjectType) {
        idsUsuarios.add(membro.UserOrGroupId);
      }
    }

    List<User> ativos = idsUsuarios.isEmpty()
      ? new List<User>()
      : [
          SELECT Id, Name, IsActive
          FROM User
          WHERE Id IN :idsUsuarios AND IsActive = true
          ORDER BY Id ASC
        ];

    if (ativos.isEmpty()) {
      throw new RosterVazioException(
        'A fila "' +
          queueDeveloperName() +
          '" não tem nenhum usuário direto ativo. Adicione vendedores à fila (time administrador Salesforce).'
      );
    }
    return ativos;
  }

  /**
   * Bloqueia o registro singleton de estado com FOR UPDATE e o devolve. O lock
   * serializa o avanço do ponteiro entre transações concorrentes e é mantido
   * até o commit.
   *
   * Localiza por Chave__c (Unique + External ID); a unicidade é garantida pelo
   * índice do campo, não por LIMIT. O registro é criado como etapa controlada
   * de implantação; o serviço nunca o cria.
   *
   * @throws SingletonAusenteException nenhum registro com essa Chave__c.
   */
  public static SOL_Distribuicao_Estado__c bloquearSingleton() {
    List<SOL_Distribuicao_Estado__c> estados = [
      SELECT
        Id,
        Name,
        Chave__c,
        Ativo__c,
        Inicio_Vigencia__c,
        Ultimo_Usuario__c,
        Data_Ultima_Distribuicao__c,
        Total_Distribuido__c
      FROM SOL_Distribuicao_Estado__c
      WHERE Chave__c = :singletonKey()
      FOR UPDATE
    ];
    if (estados.isEmpty()) {
      throw new SingletonAusenteException(
        'Registro de estado da distribuição SOL (Chave__c = "' +
          singletonKey() +
          '") não encontrado. Deve ser criado na implantação.'
      );
    }
    return estados[0];
  }
}