/**
 * CLICKUP-9398 — MOTOR de repetição diária da cadência de contato da Arnone
 * Soluções (Record Type `SOL`).
 *
 * ESCOPO: decidir QUANDO cada dia ativo da cadência vence e pedir as tarefas
 * daquele dia. Este serviço NÃO cria Task, NÃO trata idempotência, NÃO cancela,
 * NÃO preenche resultado e NÃO distribui — cada uma dessas regras já tem dono:
 *
 * - `SOLCadenciaContatoService` cria as tarefas dos três canais, com a chave
 *   (Lead, ciclo, canal, dia), o lock do Lead e as inelegibilidades;
 * - `SOLDistribuicaoService.reatribuirPorFaltaDeContato` (CLICKUP-9400) decide
 *   se um Lead esgotado troca de vendedor — inclusive a exigência de TRÊS
 *   resultados negativos, o roster, a fila e o ponteiro do round-robin;
 * - `SOLBusinessHoursHelper` responde o que é dia útil, em America/Sao_Paulo.
 *
 * O que sobra para cá, e é tudo o que esta classe faz: dado um conjunto de
 * Leads, dizer em que DIA da cadência cada um está hoje e acionar as três
 * portas existentes com o mesmo dia e o mesmo vencimento.
 *
 * ------------------------------------------------------------------ o dia
 *
 * A âncora é `Lead.SOL_Data_Inicio_Ciclo_Contato__c`, que a reatribuição
 * REINICIA — trocando de vendedor ou não. Por isso o motor não guarda estado
 * nenhum: a cadência de um Lead é sempre função do ciclo VIGENTE, e um ciclo
 * reiniciado recomeça no dia 1 sem que ninguém precise zerar contador.
 *
 * DIA 1 = a data (São Paulo) da ABERTURA do ciclo. `BusinessHours.nextStartDate`
 * devolve o próprio instante quando ele já está dentro do expediente e, fora
 * dele, a próxima abertura útil — que é exatamente a regra pedida: ciclo aberto
 * à noite, no fim de semana ou em feriado tem o dia 1 na próxima abertura útil.
 * DIA 2 e DIA 3 são os dias úteis seguintes.
 *
 * O mapeamento é feito PARA TRÁS, uma vez por transação: com `hoje` e os dois
 * dias úteis anteriores em mãos, o dia de cada Lead sai de uma comparação de
 * datas, sem repetir cálculo de calendário por registro.
 *
 * SEM BACKFILL — o motor emite SOMENTE o dia corrente. Um Lead que já está no
 * dia 2 recebe o dia 2 e nada mais: dias vencidos não são recuperados, nem
 * quando o job ficou parado. É por isso que o dia é derivado da data de HOJE em
 * vez de "o próximo dia que ainda não tem tarefa".
 *
 * ESGOTAMENTO — passado o dia 3, o motor para de criar e entrega o Lead ao
 * CLICKUP-9400. Ele não checa tentativas negativas e não força nada: se ainda
 * não houver três resultados negativos, a avaliação é NO-OP e o Lead continua
 * elegível para a próxima varredura.
 *
 * -------------------------------------------------------- ordem dos locks
 *
 * Dentro de uma transação, a reatribuição roda ANTES da criação. Ela trava
 * SINGLETON → LEAD, exatamente como a distribuição; a criação trava só o LEAD.
 * Fazendo o inverso, esta transação seguraria Leads e depois pediria o
 * singleton enquanto a distribuição segura o singleton e pede o Lead — o
 * desenho clássico de deadlock. A ordem escolhida elimina a inversão.
 *
 * ------------------------------------------------------------ atomicidade
 *
 * As três portas são chamadas sob um Savepoint PRÓPRIO do motor, criado depois
 * da reatribuição. Se qualquer canal falhar, tudo o que os canais criaram é
 * revertido: não existe "dia com e-mail mas sem WhatsApp".
 *
 * O ALCANCE desse rollback depende de quem chamou, e a diferença é real:
 *
 * - CHAMADA DIRETA a este serviço: o Savepoint cobre apenas os canais. Uma
 *   reatribuição já concluída na mesma transação NÃO é desfeita — ela ficou
 *   fora do Savepoint, de propósito.
 * - EXECUÇÃO PELO BATCH, que é o caminho de produção: `SOLCadenciaMotorBatch`
 *   LANÇA quando o resultado traz `comErro`, e essa exceção derruba a transação
 *   INTEIRA do escopo — inclusive a reatribuição que este serviço concluiu
 *   antes de abrir o Savepoint. No lote com falha, nada sobrevive.
 *
 * A distinção não é acadêmica: um mesmo escopo costuma MISTURAR Leads esgotados
 * (que vão para a reatribuição) e Leads em dia ativo (que vão para a criação).
 * Se a criação de um deles falhar, a reatribuição do outro volta atrás junto.
 * É o preço de a falha ser visível no AsyncApexJob em vez de silenciosa, e a
 * varredura seguinte recompõe as duas coisas, porque ambas são idempotentes.
 *
 * ------------------------------------------------- o dia 1 nunca se perde
 *
 * A ligação do dia 1 continua nascendo na hora da atribuição (CLICKUP-9396/9400)
 * — é a única com SLA em minutos, e o motor não entra nesse caminho crítico. Os
 * outros dois canais do dia 1 chegam na primeira varredura seguinte: como o
 * motor varre TODOS os Leads com ciclo ativo a cada execução e o núcleo absorve
 * o replay, um Lead atribuído depois da execução anterior é atendido na próxima
 * — sem acoplar a distribuição ao motor e sem uma segunda automação de criação.
 * A latência máxima é uma janela do agendador.
 *
 * Bulk-safe: nenhum SOQL/DML dentro de laço. Contexto de sistema, como os
 * demais serviços da jornada.
 */
public without sharing class SOLCadenciaMotorService {
  /** Record Type de Lead atendido — nenhuma outra BU é afetada. */
  public static final String RECORD_TYPE_DEVELOPER_NAME = 'SOL';

  /** Primeiro e último dia ativo — a faixa é do serviço de criação, não daqui. */
  public static final Integer PRIMEIRO_DIA = SOLCadenciaContatoService.DIA_PRIMEIRA_LIGACAO;
  public static final Integer ULTIMO_DIA = SOLCadenciaContatoService.DIA_MAXIMO;

  /** Mensagem controlada — sem detalhe técnico sensível. */
  @TestVisible
  private static final String MSG_ERRO_CANAIS = 'Não foi possível criar as tarefas do dia da cadência agora. Nenhuma alteração foi salva.';

  /** Configuração ausente/inválida — falha operacional, não sucesso silencioso. */
  public class ConfiguracaoInvalidaException extends Exception {
  }

  /** Relógio de referência; só testes substituem. */
  @TestVisible
  private static Datetime agoraOverride;

  /**
   * Somente testes: fixa o instante de referência do motor. Sem isto não há
   * como exercitar sexta-feira, fim de semana, virada de fuso e esgotamento de
   * forma determinística — e Apex não permite viajar no tempo de outro jeito.
   */
  public static void overrideAgora(Datetime valor) {
    if (!Test.isRunningTest()) {
      return;
    }
    agoraOverride = valor;
  }

  private static Datetime agora() {
    return agoraOverride == null ? System.now() : agoraOverride;
  }

  /**
   * Data de referência da varredura, em America/Sao_Paulo. É o único lugar que
   * converte instante em dia — o Batch usa a mesma, para que a decisão de
   * "hoje é dia útil?" no `start()` e a de "que dia da cadência é hoje?" no
   * `execute()` nunca discordem, inclusive sob o relógio de teste.
   */
  public static Date dataDeReferencia() {
    return SOLBusinessHoursHelper.dataEm(
      agora(),
      SOLBusinessHoursHelper.TZ_SAO_PAULO
    );
  }

  /** Resultado controlado de uma execução do motor. */
  public class ResultadoMotor {
    /** Hoje não tem expediente: o motor não roda em dia não útil. */
    public Boolean diaNaoUtil = false;
    /** Kill-switch da distribuição desligado (SOL_Distribuicao_Estado__c.Ativo__c). */
    public Boolean desligado = false;
    /** Leads que estavam em um dia ativo e foram enviados às três portas. */
    public Integer leadsNoDia = 0;
    /** Leads fora do escopo, sem ciclo, inelegíveis ou com o ciclo ainda por abrir. */
    public Integer leadsIgnorados = 0;
    /** Leads além do dia 3, entregues à avaliação de reatribuição (9400). */
    public Integer leadsEsgotados = 0;
    /** Tarefas efetivamente criadas, somando os três canais. */
    public Integer tarefasCriadas = 0;
    /** Pedidos absorvidos pela idempotência do núcleo (dia/canal já ocupado). */
    public Integer tarefasJaExistentes = 0;
    /** Leads que trocaram de vendedor na avaliação de esgotamento. */
    public Integer reatribuidos = 0;
    /** Esgotados com três negativas, mas sem outro vendedor disponível. */
    public Integer semOutroVendedor = 0;
    /** Leads perdidos por falha controlada (a criação foi revertida por inteiro). */
    public Integer comErro = 0;
    /** Quantos Leads em cada dia ativo — observabilidade da varredura. */
    public Map<Integer, Integer> leadsPorDia = new Map<Integer, Integer>();
    public List<String> mensagens = new List<String>();
  }

  // =====================================================================
  //  ENTRADA ÚNICA
  // =====================================================================

  /**
   * Roda a cadência do DIA CORRENTE para estes Leads.
   *
   * @param leadIds candidatos (qualquer origem; filtrados aqui e revalidados
   *        sob lock pelos serviços que têm autoridade). Nulo/vazio: zerado.
   * @throws SOLBusinessHoursHelper.CalendarioIndisponivelException se o
   *         calendário comercial estiver ausente/inativo — falha VISÍVEL, sem
   *         fallback: sem calendário não existe "dia útil" a calcular, e
   *         inventar um criaria tarefa no dia errado, em silêncio.
   * @throws ConfiguracaoInvalidaException se o singleton de estado não existir.
   */
  public static ResultadoMotor executar(List<Id> leadIds) {
    ResultadoMotor r = new ResultadoMotor();
    for (Integer dia = PRIMEIRO_DIA; dia <= ULTIMO_DIA; dia++) {
      r.leadsPorDia.put(dia, 0);
    }
    if (leadIds == null || leadIds.isEmpty()) {
      return r;
    }
    Set<Id> ids = new Set<Id>(leadIds);

    // (0) CALENDÁRIO — pré-requisito duro, sem fallback (ver @throws).
    Id bhId = SOLBusinessHoursHelper.businessHoursId();
    if (bhId == null) {
      throw new SOLBusinessHoursHelper.CalendarioIndisponivelException(
        'CLICKUP-9398 — calendário comercial da Arnone Soluções ausente ou inativo. ' +
          'O motor da cadência não roda sem ele.'
      );
    }

    // (1) KILL-SWITCH — o MESMO da distribuição (CLICKUP-9394), por decisão do
    // card: desligar a distribuição desliga a cadência que ela alimenta. Lido
    // SEM lock, como fazem as demais varreduras — tomar o singleton aqui
    // inverteria a ordem de locks descrita no cabeçalho.
    SOL_Distribuicao_Estado__c estado = SOLDistribuicaoService.lerEstado();
    if (estado == null) {
      throw new ConfiguracaoInvalidaException(
        'CLICKUP-9398 — registro de estado da distribuição SOL não encontrado. ' +
          'O motor da cadência não pode rodar sem o singleton.'
      );
    }
    if (estado.Ativo__c != true) {
      r.desligado = true;
      r.leadsIgnorados = ids.size();
      return r;
    }

    // (2) DIA NÃO ÚTIL — nenhuma execução em fim de semana ou feriado. A data é
    // a de São Paulo, não a do GMT: às 23h de São Paulo o servidor já está no
    // dia seguinte em UTC, e usar a data errada adiantaria a cadência inteira.
    Date hoje = dataDeReferencia();
    if (!SOLBusinessHoursHelper.ehDiaUtil(bhId, hoje)) {
      r.diaNaoUtil = true;
      r.leadsIgnorados = ids.size();
      return r;
    }

    // (3) As datas de corte, UMA vez por transação: com elas o dia de cada Lead
    // é uma comparação de datas, não um novo passeio pelo calendário.
    List<Date> anteriores = diasUteisAnteriores(bhId, hoje, ULTIMO_DIA - 1);

    // (4) Leitura SEM lock, de propósito: esta classificação é um PRÉ-FILTRO
    // barato. Quem decide de verdade é cada serviço, sob o seu próprio
    // FOR UPDATE — o núcleo revalida convertido, Record Type, ciclo, contato
    // efetivado, opt-out e perda antes de gravar, e a reatribuição revalida as
    // suas. Travar aqui não tornaria nada mais correto e inverteria a ordem de
    // locks.
    Map<Id, Integer> diaPorLead = new Map<Id, Integer>();
    List<Id> esgotados = new List<Id>();
    Set<Id> encontrados = new Set<Id>();
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
      WHERE Id IN :ids AND IsConverted = FALSE
    ]) {
      encontrados.add(l.Id);
      if (!elegivel(l)) {
        r.leadsIgnorados++;
        continue;
      }
      Integer dia = diaDaCadencia(
        bhId,
        l.SOL_Data_Inicio_Ciclo_Contato__c,
        hoje,
        anteriores
      );
      if (dia == null) {
        // Ciclo aberto fora do expediente e ainda por começar (o dia 1 caiu na
        // próxima abertura útil, que é depois de hoje).
        r.leadsIgnorados++;
        continue;
      }
      if (dia > ULTIMO_DIA) {
        esgotados.add(l.Id);
        continue;
      }
      diaPorLead.put(l.Id, dia);
      r.leadsPorDia.put(dia, r.leadsPorDia.get(dia) + 1);
    }
    // Convertidos e apagados nem aparecem na leitura.
    r.leadsIgnorados += (ids.size() - encontrados.size());
    r.leadsNoDia = diaPorLead.size();
    r.leadsEsgotados = esgotados.size();

    // (5) FASE 1 — ESGOTADOS. Primeiro, para manter a ordem SINGLETON → LEAD.
    if (!esgotados.isEmpty()) {
      avaliarReatribuicao(esgotados, r);
    }

    // (6) FASE 2 — DIA CORRENTE, atômico entre os três canais.
    if (!diaPorLead.isEmpty()) {
      criarDiaCorrente(diaPorLead, hoje, r);
    }
    return r;
  }

  // =====================================================================
  //  FASE 1 — ESGOTAMENTO (delegado ao CLICKUP-9400)
  // =====================================================================

  /**
   * Entrega os Leads que passaram do dia 3 à autoridade da reatribuição. O
   * motor NÃO conta tentativas, NÃO escolhe vendedor e NÃO mexe no ponteiro:
   * sem três resultados negativos no ciclo, aquela avaliação é no-op e o Lead
   * volta na próxima varredura, intacto.
   */
  private static void avaliarReatribuicao(
    List<Id> esgotados,
    ResultadoMotor r
  ) {
    SOLDistribuicaoService.ResultadoReatribuicao rr = SOLDistribuicaoService.reatribuirPorFaltaDeContato(
      esgotados
    );
    r.reatribuidos = rr.reatribuidos;
    r.semOutroVendedor = rr.semOutroVendedor;
    if (rr.comErro > 0) {
      r.comErro += rr.comErro;
      r.mensagens.addAll(rr.mensagens);
    }
  }

  // =====================================================================
  //  FASE 2 — DIA CORRENTE NOS TRÊS CANAIS
  // =====================================================================

  /**
   * Aciona `criarLigacoes`, `criarEmails` e `criarWhatsApps` com A MESMA lista
   * de pedidos — é o que garante, por construção, "mesmo dia e mesmo
   * vencimento" nos três canais, sem repetir a montagem três vezes e sem chance
   * de os canais divergirem.
   *
   * Nenhum parâmetro de canal atravessa esta fronteira: o canal é privado do
   * núcleo e cada porta é a única entrada do seu canal.
   *
   * O vencimento é HOJE em todos os canais. Na ligação do dia 1 ele é ignorado
   * pelo núcleo, que deriva o prazo dos 5 minutos úteis da atribuição — e essa
   * tarefa, na prática, já existe desde a distribuição e volta como
   * `jaExistentes`.
   *
   * ATOMICIDADE: Savepoint próprio. Cada porta já reverte a SI mesma quando
   * falha (e devolve `comErro` em vez de lançar), então sem este savepoint o
   * lote poderia terminar com ligação e e-mail criados e o WhatsApp faltando.
   * O rollback interno de uma porta não invalida este savepoint, criado ANTES
   * dela.
   *
   * O que este savepoint NÃO cobre é a reatribuição da fase anterior. Numa
   * chamada direta ao serviço ela sobrevive à falha de canal; numa execução
   * pelo Batch, a exceção que o `execute` lança depois reverte a transação
   * inteira e leva a reatribuição junto. Ver o cabeçalho da classe.
   */
  private static void criarDiaCorrente(
    Map<Id, Integer> diaPorLead,
    Date vencimento,
    ResultadoMotor r
  ) {
    List<SOLCadenciaContatoService.Solicitacao> pedidos = new List<SOLCadenciaContatoService.Solicitacao>();
    for (Id leadId : diaPorLead.keySet()) {
      pedidos.add(
        new SOLCadenciaContatoService.Solicitacao(
          leadId,
          diaPorLead.get(leadId),
          vencimento
        )
      );
    }

    Savepoint sp = Database.setSavepoint();
    try {
      List<SOLCadenciaContatoService.Resultado> porCanal = new List<SOLCadenciaContatoService.Resultado>();
      porCanal.add(SOLCadenciaContatoService.criarLigacoes(pedidos));
      // Único ponto de injeção de falha, ATIVO SOMENTE EM TESTE: é aqui que se
      // prova que o rollback apaga também o que o canal ANTERIOR já gravou.
      pontoDeFalhaDeTeste();
      porCanal.add(SOLCadenciaContatoService.criarEmails(pedidos));
      porCanal.add(SOLCadenciaContatoService.criarWhatsApps(pedidos));

      Integer criadas = 0;
      Integer jaExistentes = 0;
      Integer comErro = 0;
      for (SOLCadenciaContatoService.Resultado rc : porCanal) {
        criadas += rc.criadas;
        jaExistentes += rc.jaExistentes;
        comErro += rc.comErro;
      }

      if (comErro > 0) {
        // Um canal falhou: desfaz TAMBÉM os que deram certo. Nada de dia pela
        // metade — o retry da próxima varredura recria o dia inteiro.
        Database.rollback(sp);
        r.tarefasCriadas = 0;
        r.tarefasJaExistentes = 0;
        r.comErro += pedidos.size();
        r.mensagens.add(MSG_ERRO_CANAIS);
        return;
      }
      r.tarefasCriadas = criadas;
      r.tarefasJaExistentes = jaExistentes;
    } catch (Exception e) {
      Database.rollback(sp);
      System.debug(
        LoggingLevel.ERROR,
        'SOLCadenciaMotorService.criarDiaCorrente: ' +
          e.getTypeName() +
          ': ' +
          e.getMessage() +
          '\n' +
          e.getStackTraceString()
      );
      r.tarefasCriadas = 0;
      r.tarefasJaExistentes = 0;
      r.comErro += pedidos.size();
      r.mensagens.add(MSG_ERRO_CANAIS);
    }
  }

  /** Somente testes: força a falha DEPOIS do primeiro canal ter gravado. */
  @TestVisible
  private static Boolean falharDepoisDoPrimeiroCanal = false;

  /** Falha simulada — nunca lançada fora de um teste. */
  @TestVisible
  private class FalhaSimuladaDeCanalException extends Exception {
  }

  /**
   * SEAM DE TESTE, e nada além disso.
   *
   * O cenário que realmente importa na atomicidade é "um canal gravou, o
   * seguinte falhou, o rollback tem de apagar o que já estava gravado". As
   * falhas naturais disponíveis — proprietário inativo, por exemplo — derrubam
   * os TRÊS canais de uma vez e nunca chegam a exercitar esse ponto, então sem
   * este gancho a garantia ficaria só na documentação.
   *
   * Inerte em produção por dupla proteção: a flag nasce falsa e só é gravável
   * por `@TestVisible`, e `Test.isRunningTest()` barra a execução real mesmo se
   * alguém conseguisse ligá-la.
   */
  private static void pontoDeFalhaDeTeste() {
    if (Test.isRunningTest() && falharDepoisDoPrimeiroCanal) {
      throw new FalhaSimuladaDeCanalException(
        'CLICKUP-9398 — falha simulada de canal (somente teste).'
      );
    }
  }

  // =====================================================================
  //  CALENDÁRIO DA CADÊNCIA
  // =====================================================================

  /**
   * Em que dia ATIVO este ciclo está hoje? 1..3 para os dias ativos,
   * `ULTIMO_DIA + 1` para esgotado, e NULO quando o ciclo ainda nem começou —
   * aberto fora do expediente, com o dia 1 numa abertura útil futura.
   *
   * Função pura sobre datas já calculadas. `anteriores` traz os dias úteis
   * imediatamente anteriores a `hoje`, do mais recente para o mais antigo:
   * a posição na lista É o dia (o 1º anterior = dia 2, o 2º = dia 3).
   */
  @TestVisible
  private static Integer diaDaCadencia(
    Id bhId,
    Datetime ciclo,
    Date hoje,
    List<Date> anteriores
  ) {
    Date d1 = dataDoPrimeiroDia(bhId, ciclo);
    if (d1 == null || d1 > hoje) {
      return null;
    }
    if (d1 == hoje) {
      return PRIMEIRO_DIA;
    }
    for (Integer i = 0; i < anteriores.size(); i++) {
      if (d1 == anteriores[i]) {
        return PRIMEIRO_DIA + 1 + i;
      }
    }
    // Mais antigo que o último dia ativo: a cadência acabou. Como todo dia
    // ativo é um dia ÚTIL e `anteriores` traz os dias úteis consecutivos,
    // nenhum dia ativo pode escapar dessa lista.
    return ULTIMO_DIA + 1;
  }

  /**
   * Data (São Paulo) do DIA 1 de um ciclo: a abertura do expediente em que ele
   * efetivamente começa. Dentro do expediente é o próprio dia; à noite, no fim
   * de semana ou em feriado, `nextStartDate` empurra para a próxima abertura
   * útil — sem cálculo manual de fim de semana ou feriado.
   */
  @TestVisible
  private static Date dataDoPrimeiroDia(Id bhId, Datetime ciclo) {
    if (bhId == null || ciclo == null) {
      return null;
    }
    Datetime abertura = BusinessHours.nextStartDate(bhId, ciclo);
    return abertura == null
      ? null
      : SOLBusinessHoursHelper.dataEm(
          abertura,
          SOLBusinessHoursHelper.TZ_SAO_PAULO
        );
  }

  /**
   * Os `quantidade` dias ÚTEIS imediatamente anteriores a `origem`, do mais
   * recente para o mais antigo. Anda para trás no calendário perguntando ao
   * helper se o dia tem expediente — a mesma régua da contagem para frente.
   */
  @TestVisible
  private static List<Date> diasUteisAnteriores(
    Id bhId,
    Date origem,
    Integer quantidade
  ) {
    List<Date> datas = new List<Date>();
    Date data = origem;
    Integer guarda = 0;
    while (datas.size() < quantidade && guarda < 400) {
      data = data.addDays(-1);
      if (SOLBusinessHoursHelper.ehDiaUtil(bhId, data)) {
        datas.add(data);
      }
      guarda++;
    }
    if (datas.size() < quantidade) {
      throw new SOLBusinessHoursHelper.CalendarioIndisponivelException(
        'CLICKUP-9398 — calendário comercial sem dias úteis suficientes antes de ' +
          origem +
          '.'
      );
    }
    return datas;
  }

  /**
   * Pré-filtro em memória. Espelha as inelegibilidades que o núcleo e a
   * reatribuição revalidam sob lock — aqui só para não gastar chamada com
   * quem já se sabe fora, e para que os contadores digam a verdade.
   */
  private static Boolean elegivel(Lead l) {
    return l != null &&
      l.RecordType.DeveloperName == RECORD_TYPE_DEVELOPER_NAME &&
      l.SOL_Data_Inicio_Ciclo_Contato__c != null &&
      l.OwnerId != null &&
      l.OwnerId.getSObjectType() == User.SObjectType &&
      l.SOL_Contato_Efetivado__c != true &&
      l.SOL_Opt_Out__c != true &&
      !SOLNegocioPerdidoService.leadPerdido(l);
  }
}
