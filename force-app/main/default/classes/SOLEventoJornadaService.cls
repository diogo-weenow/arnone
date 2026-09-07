/**
 * CLICKUP-9438 — Livro-razão das reatribuições e perdas da jornada Arnone
 * Soluções. UMA linha por ocorrência, em SOL_Evento_Jornada__c.
 *
 * =====================================================================
 * POR QUE ESTE OBJETO EXISTE — e por que Owner e Field History não bastam
 * =====================================================================
 * Medido na própria org, não deduzido:
 *
 *   - `LeadHistory` só rastreia `Owner` e `Status`. Motivo da reatribuição,
 *     produto e vendedor de destino não estão lá.
 *   - O field history grava UMA LINHA POR CAMPO, todas com o mesmo timestamp.
 *     Relatório não junta duas linhas numa ocorrência: "Owner mudou" e "motivo
 *     mudou" nunca viram uma linha só.
 *   - O report type de histórico traz os campos do Lead no estado ATUAL. Com
 *     2+ reatribuições, TODAS as linhas exibem o mesmo "último motivo" — o
 *     relatório mente exatamente onde o gestor mais precisa dele.
 *   - Havia 18 trocas de `Owner` contra 9 reatribuições por prazo. Contar
 *     `Field = 'Owner'` SUPERESTIMA pela metade: transferência manual, correção
 *     de dono e reatribuição automática são a mesma linha para o histórico.
 *   - `SOL_Quantidade_Reatribuicoes__c` é contador ACUMULADO. Diz quantas
 *     foram, nunca quando, por quê, nem de quem para quem.
 *
 * Daí a regra do card: o relatório NÃO conta troca de Owner e NÃO usa Field
 * History como fonte. Conta EVENTO.
 *
 * =====================================================================
 * CONTRATO COM OS SERVIÇOS DA JORNADA
 * =====================================================================
 * Esta classe não decide nada de negócio e não dispara automação nenhuma. Quem
 * efetiva a reatribuição ou a perda continua sendo o serviço de sempre; ele
 * monta o evento com um dos construtores abaixo e chama `registrar` DENTRO do
 * próprio try/Savepoint. Disso decorrem, sem exceção:
 *
 *   - MESMA TRANSAÇÃO: o evento nasce junto com a mudança de negócio.
 *   - MESMO ROLLBACK: se a gravação do evento falhar, `registrar` RELANÇA e o
 *     Savepoint do chamador desfaz a reatribuição/perda. Nunca há reatribuição
 *     ou perda sem evento.
 *   - SEM EVENTO ÓRFÃO: se a mudança de negócio falhar, o mesmo Savepoint
 *     desfaz o evento. Nunca há evento sem a alteração correspondente.
 *   - CONTEXTO ANTES DA MUDANÇA: o vendedor e a etapa vão para o evento ANTES
 *     de o `OwnerId`/`StageName` perder o valor anterior — depois do save esse
 *     dado não existe mais em lugar nenhum consultável.
 *   - BULK: zero SOQL/DML em laço; `registrar` faz no máximo 2 consultas e 1
 *     gravação, independentemente do tamanho do lote.
 *
 * NÃO existe Flow paralelo alimentando este objeto. Um Flow separado quebraria
 * as quatro garantias acima de uma vez só.
 *
 * =====================================================================
 * IDEMPOTÊNCIA — `SOL_Chave_Idempotencia__c` (External Id + Unique)
 * =====================================================================
 * A chave identifica a OCORRÊNCIA, não o registro. `registrar` filtra o que já
 * existe antes de inserir, e o índice único do banco é a rede final: duas
 * transações concorrentes com a mesma chave não produzem duas linhas — a
 * segunda colide e derruba junto a operação de negócio duplicada.
 *
 *   FC|leadId|n  reatribuição por falta de contato, n = contador do Lead já
 *                incrementado. A 2ª reatribuição legítima nasce com n = 2 e
 *                chave diferente da 1ª; um reprocessamento da MESMA
 *                reatribuição reencontra o mesmo n e é descartado.
 *   PT|oppId|n   reatribuição por estouro do prazo total, n = contador da
 *                Oportunidade já incrementado (o serviço roda uma vez por Opp).
 *   OO|leadId    opt-out. Não leva discriminador de propósito: o serviço só age
 *                quando `SOL_Opt_Out__c` ainda é falso, então o opt-out é único
 *                e definitivo por Lead.
 *   OP|oppId|etapa   perda de Oportunidade, discriminada pela ETAPA ANTERIOR
 *                real. Reprocessar a mesma perda traz a mesma etapa e é
 *                descartado; reabrir para OUTRA etapa e perder de novo é
 *                ocorrência nova e legítima.
 *
 * LIMITAÇÃO ACEITA E DOCUMENTADA da chave da perda: reabrir para a MESMA etapa
 * e perder outra vez reaproveita a chave e não gera segunda ocorrência. A
 * alternativa seria um contador de perdas na própria Oportunidade, o que
 * exigiria DML na Oportunidade dentro do after-save — acoplando o fechamento do
 * negócio a uma gravação analítica, exatamente o que o CLICKUP-9439 evitou ao
 * pôr `SOL_Data_Encerramento__c` em before-save. Preferimos perder uma
 * ocorrência rara a poder abortar uma venda.
 *
 * =====================================================================
 * PROPRIETÁRIO DO EVENTO
 * =====================================================================
 * OWD Private e proprietário = vendedor responsável no instante da ocorrência
 * (nas reatribuições, o vendedor ANTERIOR). O gestor consolida pelo modelo de
 * acesso vigente — hierarquia de papéis —, sem "View All".
 *
 * A plataforma recusa atribuir registro a usuário INATIVO. Então o proprietário
 * só recebe o vendedor quando ele está ativo; caso contrário fica com o usuário
 * da automação. `SOL_Vendedor__c` NUNCA é afetado por isso: ele é a fonte de
 * verdade do "de quem", e é dele que o relatório vive. Ownership aqui é
 * compartilhamento, não dado.
 *
 * =====================================================================
 * SEM BACKFILL
 * =====================================================================
 * A série começa na data de implantação. O histórico anterior não é
 * correlacionável com segurança — é justamente o que as 18 trocas de Owner
 * contra 9 reatribuições provam. Estimar seria inventar número para gestor.
 */
public without sharing class SOLEventoJornadaService {
  // ------------------------------------------------------------ vocabulário

  /** Valores de `SOL_Tipo_Evento__c`. */
  public static final String TIPO_REATRIBUICAO = 'Reatribuição';
  public static final String TIPO_PERDA = 'Perda';

  /** Valores de `SOL_Motivo__c` — os quatro motivos do card, sem sinônimos. */
  public static final String MOTIVO_FALTA_CONTATO = 'Reatribuição por falta de contato';
  public static final String MOTIVO_PRAZO_TOTAL = 'Reatribuição por estouro do prazo total';
  public static final String MOTIVO_OPT_OUT = 'Lead perdido por opt-out';
  public static final String MOTIVO_OPORTUNIDADE_PERDIDA = 'Oportunidade perdida';

  /** Valores de `SOL_Origem__c`. */
  public static final String ORIGEM_LEAD = 'Lead';
  public static final String ORIGEM_OPORTUNIDADE = 'Oportunidade';

  /** Etapa que NUNCA pode ser gravada como etapa anterior de uma perda. */
  public static final String ETAPA_PERDIDO = 'Perdido';

  private static final String PREFIXO_FALTA_CONTATO = 'FC';
  private static final String PREFIXO_PRAZO_TOTAL = 'PT';
  private static final String PREFIXO_OPT_OUT = 'OO';
  private static final String PREFIXO_PERDA_OPORTUNIDADE = 'OP';

  /** Tamanho de `SOL_Chave_Idempotencia__c`. Chave maior é defeito, não dado. */
  @TestVisible
  private static final Integer MAX_CHAVE = 120;

  /** Tamanho de `SOL_Etapa_Anterior__c` e `SOL_Record_Type_Origem__c`. */
  @TestVisible
  private static final Integer MAX_TEXTO = 80;

  /**
   * Falha controlada do registro do evento. Sempre RELANÇADA para o serviço de
   * negócio, que a converte na mensagem da própria operação e desfaz tudo pelo
   * Savepoint. Nunca é engolida: evento faltando é número errado para o gestor,
   * e "o Apex ignora" não é proteção.
   */
  public class EventoJornadaException extends Exception {
  }

  /** Defeito de programação do chamador (projeção/argumento faltando). */
  public static final String MSG_EVENTO_INVALIDO = 'Não foi possível registrar a ocorrência da jornada da Arnone Soluções: o evento chegou incompleto ao serviço.';

  /** Perda de Oportunidade sem a etapa de origem da transição. */
  public static final String MSG_ETAPA_ANTERIOR_AUSENTE = 'Não foi possível registrar a perda desta Oportunidade: a etapa anterior à perda não foi informada pela automação. Nada foi salvo.';

  // ------------------------------------------------------------ construtores

  /**
   * Reatribuição por falta de contato (CLICKUP-9400) — origem Lead.
   *
   * @param lead Lead JÁ carregado, com `RecordType.DeveloperName` e
   *   `SOL_Produto_Interesse__c` na projeção. Se faltarem, a leitura estoura
   *   `SObjectException` e a transação inteira cai — de propósito: evento sem
   *   Record Type sairia do filtro travado do relatório em silêncio.
   * @param vendedorAnterior proprietário ANTES da troca (capture antes de
   *   sobrescrever `OwnerId`).
   * @param novoVendedor proprietário escolhido pelo round-robin.
   * @param sequencia `SOL_Quantidade_Reatribuicoes__c` JÁ incrementado.
   * @param quando instante da reatribuição — o mesmo carimbado no Lead.
   */
  public static SOL_Evento_Jornada__c reatribuicaoPorFaltaDeContato(
    Lead lead,
    Id vendedorAnterior,
    Id novoVendedor,
    Decimal sequencia,
    Datetime quando
  ) {
    SOL_Evento_Jornada__c e = base(
      TIPO_REATRIBUICAO,
      MOTIVO_FALTA_CONTATO,
      ORIGEM_LEAD,
      quando,
      sequencia
    );
    e.SOL_Lead__c = lead == null ? null : lead.Id;
    e.SOL_Produto__c = lead == null ? null : lead.SOL_Produto_Interesse__c;
    e.SOL_Record_Type_Origem__c = lead == null
      ? null
      : truncar(lead.RecordType.DeveloperName, MAX_TEXTO);
    e.SOL_Vendedor__c = vendedorAnterior;
    e.SOL_Novo_Vendedor__c = novoVendedor;
    e.SOL_Chave_Idempotencia__c = chave(
      PREFIXO_FALTA_CONTATO,
      e.SOL_Lead__c,
      formatarSequencia(sequencia)
    );
    return e;
  }

  /**
   * Reatribuição por estouro do prazo total de 30 dias úteis (CLICKUP-9424) —
   * origem Oportunidade.
   *
   * @param oportunidade Oportunidade JÁ carregada, com
   *   `RecordType.DeveloperName` e `SOL_Produto_Negocio__c` na projeção.
   * @param vendedorAnterior proprietário ANTES da troca.
   * @param novoVendedor proprietário escolhido pelo round-robin.
   * @param sequencia `SOL_Qtd_Reatribuicoes_Prazo__c` JÁ incrementado.
   * @param quando instante da reatribuição — o mesmo carimbado na Oportunidade.
   */
  public static SOL_Evento_Jornada__c reatribuicaoPorPrazoTotal(
    Opportunity oportunidade,
    Id vendedorAnterior,
    Id novoVendedor,
    Decimal sequencia,
    Datetime quando
  ) {
    SOL_Evento_Jornada__c e = base(
      TIPO_REATRIBUICAO,
      MOTIVO_PRAZO_TOTAL,
      ORIGEM_OPORTUNIDADE,
      quando,
      sequencia
    );
    e.SOL_Oportunidade__c = oportunidade == null ? null : oportunidade.Id;
    e.SOL_Produto__c = oportunidade == null
      ? null
      : oportunidade.SOL_Produto_Negocio__c;
    e.SOL_Record_Type_Origem__c = oportunidade == null
      ? null
      : truncar(oportunidade.RecordType.DeveloperName, MAX_TEXTO);
    e.SOL_Vendedor__c = vendedorAnterior;
    e.SOL_Novo_Vendedor__c = novoVendedor;
    e.SOL_Chave_Idempotencia__c = chave(
      PREFIXO_PRAZO_TOTAL,
      e.SOL_Oportunidade__c,
      formatarSequencia(sequencia)
    );
    return e;
  }

  /**
   * Lead perdido por opt-out (CLICKUP-9418) — origem Lead, sem novo vendedor.
   *
   * Sequência fixa em 1 e chave sem discriminador: o serviço só desqualifica
   * quem ainda não estava em opt-out, então a ocorrência é única e definitiva
   * por Lead. Um segundo disparo não chega até aqui.
   *
   * @param lead Lead JÁ carregado, com `OwnerId`, `RecordType.DeveloperName` e
   *   `SOL_Produto_Interesse__c` na projeção.
   * @param quando instante do opt-out — o mesmo carimbado no Lead.
   */
  public static SOL_Evento_Jornada__c leadPerdidoPorOptOut(
    Lead lead,
    Datetime quando
  ) {
    SOL_Evento_Jornada__c e = base(
      TIPO_PERDA,
      MOTIVO_OPT_OUT,
      ORIGEM_LEAD,
      quando,
      1
    );
    e.SOL_Lead__c = lead == null ? null : lead.Id;
    e.SOL_Produto__c = lead == null ? null : lead.SOL_Produto_Interesse__c;
    e.SOL_Record_Type_Origem__c = lead == null
      ? null
      : truncar(lead.RecordType.DeveloperName, MAX_TEXTO);
    e.SOL_Vendedor__c = lead == null ? null : lead.OwnerId;
    e.SOL_Chave_Idempotencia__c = chave(
      PREFIXO_OPT_OUT,
      e.SOL_Lead__c,
      null
    );
    return e;
  }

  /**
   * Oportunidade perdida / Closed Lost (CLICKUP-9425) — origem Oportunidade,
   * sem novo vendedor.
   *
   * `etapaAnterior` é a etapa REAL de onde a Oportunidade saiu, vinda de
   * `$Record__Prior.StageName` no Flow after-save. NUNCA "Perdido": gravar
   * "Perdido" como etapa anterior seria registrar o destino no lugar da origem
   * e apagar justamente a informação que o card pede. Ausente ou igual a
   * "Perdido" faz `registrar` RELANÇAR — a perda é abortada em vez de virar
   * linha errada no relatório do gestor.
   *
   * @param oportunidade Oportunidade JÁ carregada, com `OwnerId`,
   *   `RecordType.DeveloperName` e `SOL_Produto_Negocio__c` na projeção.
   * @param etapaAnterior etapa imediatamente anterior à perda.
   * @param quando instante da perda.
   */
  public static SOL_Evento_Jornada__c oportunidadePerdida(
    Opportunity oportunidade,
    String etapaAnterior,
    Datetime quando
  ) {
    SOL_Evento_Jornada__c e = base(
      TIPO_PERDA,
      MOTIVO_OPORTUNIDADE_PERDIDA,
      ORIGEM_OPORTUNIDADE,
      quando,
      1
    );
    e.SOL_Oportunidade__c = oportunidade == null ? null : oportunidade.Id;
    e.SOL_Produto__c = oportunidade == null
      ? null
      : oportunidade.SOL_Produto_Negocio__c;
    e.SOL_Record_Type_Origem__c = oportunidade == null
      ? null
      : truncar(oportunidade.RecordType.DeveloperName, MAX_TEXTO);
    e.SOL_Vendedor__c = oportunidade == null ? null : oportunidade.OwnerId;
    e.SOL_Etapa_Anterior__c = truncar(etapaAnterior, MAX_TEXTO);
    e.SOL_Chave_Idempotencia__c = chave(
      PREFIXO_PERDA_OPORTUNIDADE,
      e.SOL_Oportunidade__c,
      e.SOL_Etapa_Anterior__c
    );
    return e;
  }

  // ------------------------------------------------------------- gravação

  /**
   * Grava as ocorrências que ainda não existem. Chame DENTRO do try/Savepoint
   * do serviço de negócio.
   *
   * Custo fixo: 1 consulta de chaves + 1 consulta de usuários + 1 `insert`,
   * qualquer que seja o tamanho do lote. Zero SOQL/DML em laço.
   *
   * @param eventos eventos montados pelos construtores desta classe.
   * @return quantos eventos NOVOS foram gravados (0 quando tudo já existia).
   * @throws EventoJornadaException evento incompleto — defeito do chamador.
   *   Qualquer falha de DML sobe como está: o Savepoint do chamador desfaz a
   *   operação de negócio junto.
   */
  public static Integer registrar(List<SOL_Evento_Jornada__c> eventos) {
    if (eventos == null || eventos.isEmpty()) {
      return 0;
    }

    // 1. Validação. Entrada inválida NUNCA é descartada em silêncio: sem esta
    //    porta, um evento sem Record Type ou sem motivo entraria no banco e o
    //    relatório passaria a mentir sem erro nenhum aparecer.
    Set<String> chaves = new Set<String>();
    for (SOL_Evento_Jornada__c e : eventos) {
      validar(e);
      chaves.add(e.SOL_Chave_Idempotencia__c);
    }

    // 2. Ocorrências já gravadas (reprocessamento, replay do Flow, segunda
    //    varredura). Uma consulta para o lote inteiro.
    Set<String> jaGravadas = new Set<String>();
    for (SOL_Evento_Jornada__c e : [
      SELECT SOL_Chave_Idempotencia__c
      FROM SOL_Evento_Jornada__c
      WHERE SOL_Chave_Idempotencia__c IN :chaves
    ]) {
      jaGravadas.add(e.SOL_Chave_Idempotencia__c);
    }

    // 3. Deduplicação DENTRO do próprio lote: a mesma chave duas vezes na
    //    mesma chamada é uma ocorrência só. O Map preserva a primeira.
    Map<String, SOL_Evento_Jornada__c> novos = new Map<String, SOL_Evento_Jornada__c>();
    Set<Id> vendedores = new Set<Id>();
    for (SOL_Evento_Jornada__c e : eventos) {
      if (jaGravadas.contains(e.SOL_Chave_Idempotencia__c)) {
        continue;
      }
      if (novos.containsKey(e.SOL_Chave_Idempotencia__c)) {
        continue;
      }
      novos.put(e.SOL_Chave_Idempotencia__c, e);
      if (e.SOL_Vendedor__c != null) {
        vendedores.add(e.SOL_Vendedor__c);
      }
    }
    if (novos.isEmpty()) {
      return 0;
    }

    // 4. Proprietário = vendedor da ocorrência, quando ele ainda está ATIVO.
    //    A plataforma recusa atribuir registro a usuário inativo, e um vendedor
    //    desligado não pode derrubar a reatribuição de quem ficou. O dado
    //    continua íntegro em SOL_Vendedor__c.
    Set<Id> ativos = new Set<Id>();
    if (!vendedores.isEmpty()) {
      for (User u : [
        SELECT Id
        FROM User
        WHERE Id IN :vendedores AND IsActive = true
      ]) {
        ativos.add(u.Id);
      }
    }

    List<SOL_Evento_Jornada__c> paraInserir = new List<SOL_Evento_Jornada__c>();
    for (SOL_Evento_Jornada__c e : novos.values()) {
      if (e.SOL_Vendedor__c != null && ativos.contains(e.SOL_Vendedor__c)) {
        e.OwnerId = e.SOL_Vendedor__c;
      }
      paraInserir.add(e);
    }

    // 5. All-or-none. Falha aqui SOBE: o Savepoint do chamador desfaz a
    //    reatribuição ou a perda. É a garantia "nunca sem evento".
    gravar(paraInserir);
    return paraInserir.size();
  }

  // -------------------------------------------------------------- internos

  private static SOL_Evento_Jornada__c base(
    String tipo,
    String motivo,
    String origem,
    Datetime quando,
    Decimal sequencia
  ) {
    return new SOL_Evento_Jornada__c(
      SOL_Tipo_Evento__c = tipo,
      SOL_Motivo__c = motivo,
      SOL_Origem__c = origem,
      SOL_Data_Ocorrencia__c = quando,
      SOL_Sequencia__c = sequencia
    );
  }

  /**
   * `PREFIXO|Id de 18` mais, quando houver, `|discriminador`. Ids em Apex vêm
   * sempre com 18 caracteres, então a chave é estável entre transações.
   */
  private static String chave(
    String prefixo,
    Id registro,
    String discriminador
  ) {
    if (registro == null) {
      return null;
    }
    String c = prefixo + '|' + String.valueOf(registro);
    if (String.isNotBlank(discriminador)) {
      c += '|' + discriminador;
    }
    return truncar(c, MAX_CHAVE);
  }

  /** Sequência sem casas decimais na chave: 2 e 2.0 não podem ser chaves diferentes. */
  private static String formatarSequencia(Decimal sequencia) {
    return sequencia == null
      ? null
      : String.valueOf(sequencia.setScale(0, System.RoundingMode.DOWN).longValue());
  }

  private static String truncar(String valor, Integer tamanho) {
    return String.isBlank(valor) ? valor : valor.abbreviate(tamanho);
  }

  /**
   * Recusa qualquer evento incompleto. Cada checagem existe porque a ausência
   * correspondente produziria número errado sem produzir erro nenhum.
   */
  private static void validar(SOL_Evento_Jornada__c e) {
    if (e == null) {
      throw new EventoJornadaException(MSG_EVENTO_INVALIDO);
    }
    if (
      String.isBlank(e.SOL_Tipo_Evento__c) ||
      String.isBlank(e.SOL_Motivo__c) ||
      String.isBlank(e.SOL_Origem__c) ||
      String.isBlank(e.SOL_Chave_Idempotencia__c) ||
      String.isBlank(e.SOL_Record_Type_Origem__c) ||
      e.SOL_Data_Ocorrencia__c == null ||
      e.SOL_Sequencia__c == null
    ) {
      throw new EventoJornadaException(MSG_EVENTO_INVALIDO);
    }
    // Origem e lookup precisam concordar: sem isso o relatório perde a linha de
    // detalhe e ninguém consegue auditar a ocorrência.
    if (e.SOL_Origem__c == ORIGEM_LEAD && e.SOL_Lead__c == null) {
      throw new EventoJornadaException(MSG_EVENTO_INVALIDO);
    }
    if (
      e.SOL_Origem__c == ORIGEM_OPORTUNIDADE &&
      e.SOL_Oportunidade__c == null
    ) {
      throw new EventoJornadaException(MSG_EVENTO_INVALIDO);
    }
    // Perda de Oportunidade sem a etapa REAL de origem — ou com "Perdido", que
    // é o destino e não a origem — não vira linha de relatório.
    if (e.SOL_Motivo__c == MOTIVO_OPORTUNIDADE_PERDIDA) {
      if (
        String.isBlank(e.SOL_Etapa_Anterior__c) ||
        e.SOL_Etapa_Anterior__c == ETAPA_PERDIDO
      ) {
        throw new EventoJornadaException(MSG_ETAPA_ANTERIOR_AUSENTE);
      }
    }
  }

  /**
   * Somente testes: derruba o `insert` para comprovar que a falha do evento
   * desfaz a operação de negócio. Não há como derrubar este DML por dados (o
   * objeto não tem Validation Rule nem lookup filter), então a injeção é
   * explícita e blindada por `Test.isRunningTest()` — mesmo padrão de
   * `SOLPrazoTotalService.falharGravacaoDoPonteiro`.
   */
  @TestVisible
  private static Boolean falharGravacao = false;

  private static void gravar(List<SOL_Evento_Jornada__c> eventos) {
    if (Test.isRunningTest() && falharGravacao) {
      throw new EventoJornadaException(
        'Falha de gravação do evento injetada pelo teste.'
      );
    }
    insert eventos;
  }
}
