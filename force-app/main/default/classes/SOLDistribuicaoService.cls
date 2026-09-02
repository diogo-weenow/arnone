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

  /** Resultados que contam como tentativa sem contato. */
  @TestVisible
  private static final Set<String> RESULTADOS_NEGATIVOS = new Set<String>{
    RESULTADO_NAO_ATENDEU,
    RESULTADO_NAO_FOI_POSSIVEL
  };
  /** Todos os resultados considerados na contagem do ciclo. */
  @TestVisible
  private static final Set<String> RESULTADOS_CONSIDERADOS = new Set<String>{
    RESULTADO_ATENDEU,
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

  /** Assunto da Task criada após toda atribuição bem-sucedida. */
  @TestVisible
  private static final String SUBJECT_PRIMEIRA_LIGACAO = '1ª Ligação';
  /** Valor de Status aberto válido na org (TaskStatus IsClosed = false). */
  @TestVisible
  private static final String TASK_STATUS_ABERTO = 'Open';

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
  /** Business Hours para o cálculo do prazo (etapa controlada de implantação). */
  @TestVisible
  private static final String BUSINESS_HOURS_NAME = 'Arnone Soluções - Horário Comercial';
  /** Prazo operacional: 5 minutos ÚTEIS após a atribuição. */
  @TestVisible
  private static final Long PRAZO_CONTATO_MS = 5L * 60L * 1000L;

  private static Id bhCache;
  private static Boolean bhResolvido = false;

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

  /** Resultado controlado do contato efetivado (CLICKUP-9417). */
  public class ResultadoContatoEfetivado {
    /** Leads marcados como "contato efetivado" agora. */
    public Integer leadsSinalizados = 0;
    /** Tarefas de contato pendentes canceladas. */
    public Integer tarefasCanceladas = 0;
    /** Leads fora do escopo (outro Record Type, convertido, inexistente). */
    public Integer ignorados = 0;
    /** Leads não processados por erro controlado. */
    public Integer comErro = 0;
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

      // (7) Leads em ordem determinística, relidos DEPOIS da trava — assim uma
      // execução concorrente enxerga o status já gravado pela outra e não
      // redistribui. Só não convertidos: um Lead convertido já tem dono final.
      List<Lead> carregados = [
        SELECT
          Id,
          OwnerId,
          CreatedDate,
          RecordType.DeveloperName,
          SOL_Status_Distribuicao__c
        FROM Lead
        WHERE Id IN :ids AND IsConverted = false
        ORDER BY CreatedDate ASC, Id ASC
      ];

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
      Map<Id, Id> donoPorLead = new Map<Id, Id>();
      for (Integer i = 0; i < elegiveis.size(); i++) {
        Lead l = elegiveis[i];
        l.OwnerId = ativos[Math.mod(inicio + i, n)].Id;
        l.SOL_Status_Distribuicao__c = STATUS_DISTRIBUIDO;
        l.SOL_Data_Distribuicao__c = agora;
        l.SOL_Erro_Distribuicao__c = null;
        // CLICKUP-9400: abre o ciclo de contato do vendedor que recebeu o Lead.
        l.SOL_Data_Inicio_Ciclo_Contato__c = agora;
        l.SOL_Status_Reatribuicao__c = REATRIB_EM_ACOMPANHAMENTO;
        donoPorLead.put(l.Id, l.OwnerId);
      }
      update elegiveis;

      // (CLICKUP-9396) Task "1ª Ligação" — uma por atribuição bem-sucedida.
      // Dentro do try/Savepoint: se a criação falhar, o rollback desfaz o Owner
      // e o ponteiro NÃO avança (nenhuma inconsistência).
      List<Task> tarefasLigacao = montarTasksPrimeiraLigacao(donoPorLead, agora);
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

    List<Lead> paraErro = [
      SELECT Id
      FROM Lead
      WHERE
        Id IN :ids
        AND RecordType.DeveloperName = :RECORD_TYPE_DEVELOPER_NAME
        AND IsConverted = false
        AND (SOL_Status_Distribuicao__c = null
        OR SOL_Status_Distribuicao__c != :STATUS_DISTRIBUIDO)
    ];
    for (Lead l : paraErro) {
      if (filaId != null) {
        l.OwnerId = filaId;
      }
      l.SOL_Status_Distribuicao__c = STATUS_ERRO;
      l.SOL_Erro_Distribuicao__c = mensagem;
      l.SOL_Data_Distribuicao__c = agora;
    }
    if (!paraErro.isEmpty()) {
      // best-effort: marcar o erro nunca deve relançar nem bloquear a criação.
      Database.update(paraErro, false);
    }
    r.comErro = paraErro.size();
    r.mensagens.add(mensagem);
  }

  private static Integer indiceDe(List<User> lista, Id alvo) {
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
   * concluídas com resultado "Sem sucesso" — desde que nenhuma Task do ciclo
   * tenha resultado "Sucesso" (contato efetivado bloqueia a troca do ciclo).
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

      List<Lead> carregados = [
        SELECT
          Id,
          OwnerId,
          RecordType.DeveloperName,
          SOL_Data_Inicio_Ciclo_Contato__c,
          SOL_Quantidade_Reatribuicoes__c
        FROM Lead
        WHERE Id IN :ids AND IsConverted = false
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
      // possível ligar" contam como tentativa negativa.
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
      Map<Id, Id> donoPorLeadReatribuido = new Map<Id, Id>();

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
        donoPorLeadReatribuido.put(l.Id, escolhido);
      }

      if (!leadsAlterados.isEmpty()) {
        update leadsAlterados;
      }
      // (CLICKUP-9396) Task "1ª Ligação" — uma por reatribuição efetivada.
      // Dentro do try/Savepoint: falha aqui faz rollback e o ponteiro não avança.
      List<Task> tarefasNovas = montarTasksPrimeiraLigacao(
        donoPorLeadReatribuido,
        agora
      );
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
   */
  private static Id proximoVendedorExcluindo(
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
   * Bulk-safe: nenhuma consulta ou DML dentro de laço. Transacional:
   * Savepoint/rollback. Concorrência: os Leads são travados com FOR UPDATE, o
   * que serializa dois "Atendeu" simultâneos do mesmo Lead. Idempotente: um 2º
   * disparo não encontra mais tarefas pendentes e não reprocessa o flag.
   * Recursão: as tarefas ficam com Status "Cancelada" e sem resultado "Atendeu"
   * — o Flow SOL_Contato_Efetivado não volta a disparar.
   *
   * NÃO altera tarefas já concluídas (Status "Completed"): o histórico de
   * tentativas anteriores permanece intacto. NÃO altera o status do funil do
   * Lead nem cria tarefas.
   *
   * @param leadIds Ids de Lead (qualquer origem; filtrados aqui para RT SOL).
   * @return contagens controladas.
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

    Savepoint sp = Database.setSavepoint();
    try {
      // Trava os Leads: serializa dois "Atendeu" concorrentes do mesmo Lead.
      List<Lead> carregados = [
        SELECT
          Id,
          RecordType.DeveloperName,
          SOL_Contato_Efetivado__c,
          SOL_Data_Contato_Efetivado__c
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
      Database.rollback(sp);
      System.debug(
        LoggingLevel.ERROR,
        'SOLDistribuicaoService.registrarContatoEfetivado: ' +
          e.getTypeName() +
          ': ' +
          e.getMessage() +
          '\n' +
          e.getStackTraceString()
      );
      r.comErro = ids.size();
      return r;
    }
  }

  // =====================================================================
  //  TASK "1ª LIGAÇÃO" — CRIAÇÃO CENTRALIZADA (CLICKUP-9396)
  // =====================================================================

  /**
   * Monta, em bulk, a Task "1ª Ligação" para cada Lead recém-atribuído.
   * Reutilizada pela distribuição inicial (incl. reprocessamento que distribui)
   * e pela reatribuição por falta de contato. NÃO faz SOQL/DML em laço — o
   * Business Hours é resolvido uma única vez. O chamador insere as Tasks dentro
   * da mesma transação/Savepoint do serviço.
   *
   * Prazo = 5 minutos ÚTEIS após `atribuicao`, calculado com `BusinessHours.add`
   * sobre o Business Hours "Arnone Soluções - Horário Comercial": se a
   * atribuição cai fora do expediente a contagem começa no próximo período
   * útil; se o expediente encerra no meio dos 5 minutos, o saldo segue no
   * próximo período. Sem cálculo manual de fim de semana.
   *
   * @param donoPorLead Lead Id -> OwnerId (vendedor que recebeu o Lead)
   * @param atribuicao  instante da atribuição/reatribuição
   */
  @TestVisible
  private static List<Task> montarTasksPrimeiraLigacao(
    Map<Id, Id> donoPorLead,
    Datetime atribuicao
  ) {
    List<Task> tarefas = new List<Task>();
    if (donoPorLead == null || donoPorLead.isEmpty()) {
      return tarefas;
    }
    Id bhId = businessHoursComercialId();
    for (Id leadId : donoPorLead.keySet()) {
      Datetime prazo = (bhId != null)
        ? BusinessHours.add(bhId, atribuicao, PRAZO_CONTATO_MS)
        : atribuicao.addMinutes(5);
      tarefas.add(
        new Task(
          Subject = SUBJECT_PRIMEIRA_LIGACAO,
          WhoId = leadId,
          OwnerId = donoPorLead.get(leadId),
          Status = TASK_STATUS_ABERTO,
          ActivityDate = prazo.dateGmt(),
          SOL_Prazo_Contato__c = prazo,
          // CLICKUP-9417: classificador técnico (o Subject é editável e não deve
          // ser a identificação da tarefa de contato).
          SOL_Tipo_Tarefa__c = TIPO_TAREFA_CONTATO
          // SOL_Resultado_Contato__c fica vazio (preenchido pelo vendedor).
        )
      );
    }
    return tarefas;
  }

  /**
   * Id do Business Hours "Arnone Soluções - Horário Comercial" (ativo), ou null
   * se ainda não foi criado. Resolvido uma única vez por transação.
   */
  @TestVisible
  private static Id businessHoursComercialId() {
    if (!bhResolvido) {
      List<BusinessHours> bhs = [
        SELECT Id
        FROM BusinessHours
        WHERE Name = :BUSINESS_HOURS_NAME AND IsActive = true
        LIMIT 1
      ];
      bhCache = bhs.isEmpty() ? null : bhs[0].Id;
      bhResolvido = true;
    }
    return bhCache;
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