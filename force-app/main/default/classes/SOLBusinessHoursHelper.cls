/**
 * Cálculo de prazos em DIAS ÚTEIS para as automações da jornada Arnone
 * Soluções — lógica única, validada no CLICKUP-9401 (PR #8) e reutilizada pelo
 * CLICKUP-9426.
 *
 * Um dia de calendário conta como dia útil quando POSSUI algum período de
 * expediente nele, verificado pela ABERTURA EFETIVA do dia
 * (BusinessHours.nextStartDate a partir da véspera à noite) — nunca pelo
 * horário da origem. Assim uma sexta que encerra às 17:00 conta como dia útil
 * mesmo quando a origem foi numa quinta às 17:30. Fim de semana, feriados do
 * calendário e o timezone America/Sao_Paulo são preservados. Sem addDays(N),
 * sem grade fixa de segunda a sexta e sem fallback silencioso.
 *
 * Não faz DML. Não conhece Lead, Task nem os serviços que a consomem.
 */
public with sharing class SOLBusinessHoursHelper {
  /** Timezone de referência da operação comercial. */
  public static final String TZ_SAO_PAULO = 'America/Sao_Paulo';

  @TestVisible
  private static final String BUSINESS_HOURS_NAME = 'Arnone Soluções - Horário Comercial';

  /** Calendário comercial ausente/inativo ou sem dias úteis suficientes. */
  public class CalendarioIndisponivelException extends Exception {
  }

  /**
   * (CLICKUP-9439 / CLICKUP-9429 absorvido) Intervalo que não pode ser contado
   * porque o DADO está incoerente — destino anterior à origem, ou distância de
   * calendário maior do que qualquer etapa comercial plausível.
   *
   * Distinta de CalendarioIndisponivelException DE PROPÓSITO: aquela é falha
   * TRANSITÓRIA de infraestrutura (o Business Hours voltou a ser publicado e a
   * conta passa a funcionar), esta é dado inválido e não melhora sozinha com o
   * tempo. Quem trata as duas — SOLDuracaoEtapaService — registra motivos de
   * pendência diferentes, e só o motivo transitório é reprocessado pelo Batch.
   * Sem essa separação, um intervalo incoerente entraria em retry perpétuo.
   */
  public class IntervaloInvalidoException extends Exception {
  }

  /**
   * Teto de dias de CALENDÁRIO admitido num único intervalo, e ao mesmo tempo a
   * guarda contra laço infinito de `diasUteisEntre`/`diasUteisNoIntervalo` —
   * o mesmo papel que o `guarda < 400` cumpre em `prazoEmDiasUteis`.
   *
   * 4000 dias são cerca de onze anos: nenhuma etapa da jornada Arnone Soluções
   * dura isso. Um par de marcos mais distante que esse teto é dado incoerente,
   * e é tratado como tal (IntervaloInvalidoException), não como calendário
   * ausente — de novo, para não gerar reprocessamento eterno.
   */
  public static final Integer MAX_DIAS_INTERVALO = 4000;

  @TestVisible
  private static Id bhCache;
  @TestVisible
  private static Boolean bhResolvido = false;

  /**
   * Id do Business Hours "Arnone Soluções - Horário Comercial" (ativo), ou null
   * se não existir / não estiver ativo. Resolvido uma única vez por transação.
   */
  public static Id businessHoursId() {
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

  /** Somente testes: força o cache do Business Hours (ex.: calendário ausente). */
  public static void overrideBusinessHours(Id valor) {
    if (!Test.isRunningTest()) {
      return;
    }
    bhCache = valor;
    bhResolvido = true;
  }

  /** Data no fuso `tz` correspondente ao instante `dt` (sem deslocamento GMT). */
  public static Date dataEm(Datetime dt, String tz) {
    return Date.valueOf(dt.format('yyyy-MM-dd', tz));
  }

  /**
   * Abertura EFETIVA do expediente no dia `data` (America/Sao_Paulo), ou null
   * quando aquele dia não tem expediente algum — fim de semana ou feriado do
   * calendário.
   *
   * (CLICKUP-9398) EXTRAÍDO do miolo de `prazoEmDiasUteis`, sem mudar uma linha
   * do cálculo: a régua de "este dia é útil?" passa a ter UM dono, consumido
   * tanto pela contagem para frente (prazos) quanto pelo motor da cadência, que
   * precisa da mesma régua para andar para trás e para recusar rodar em dia sem
   * expediente.
   *
   * A sonda parte de 00:00 GMT da data — que em São Paulo é a véspera à noite,
   * sempre fora de expediente —, então `nextStartDate` devolve a próxima
   * abertura de VERDADE. Se ela cair em outro dia, este dia não tem expediente.
   */
  public static Datetime aberturaDoDia(Id bhId, Date data) {
    if (bhId == null || data == null) {
      return null;
    }
    Datetime antesDaAbertura = Datetime.newInstanceGmt(
      data,
      Time.newInstance(0, 0, 0, 0)
    );
    Datetime proximaAbertura = BusinessHours.nextStartDate(
      bhId,
      antesDaAbertura
    );
    return (proximaAbertura != null &&
      dataEm(proximaAbertura, TZ_SAO_PAULO) == data)
      ? proximaAbertura
      : null;
  }

  /**
   * Este dia de calendário POSSUI expediente? Fim de semana e feriado: false.
   * Sem calendário disponível também é false — quem precisa distinguir
   * "não é dia útil" de "não há calendário" deve checar `businessHoursId()`
   * antes, porque aqui os dois casos se parecem. CLICKUP-9398.
   */
  public static Boolean ehDiaUtil(Id bhId, Date data) {
    return aberturaDoDia(bhId, data) != null;
  }

  /**
   * Abertura efetiva do dia útil que fica `dias` dias ÚTEIS depois da DATA
   * (America/Sao_Paulo) de `origem`.
   *
   * @throws CalendarioIndisponivelException se `bhId` for nulo ou o calendário
   *   não tiver dias úteis suficientes.
   */
  public static Datetime prazoEmDiasUteis(Id bhId, Datetime origem, Integer dias) {
    if (bhId == null) {
      throw new CalendarioIndisponivelException(
        'Business Hours "' + BUSINESS_HOURS_NAME + '" ausente ou inativo.'
      );
    }
    Date data = dataEm(origem, TZ_SAO_PAULO);
    Integer contados = 0;
    Integer guarda = 0;
    Datetime abertura = null;
    while (contados < dias && guarda < 400) {
      data = data.addDays(1);
      // Mesma verificação de sempre, agora com um dono só (`aberturaDoDia`).
      Datetime proximaAbertura = aberturaDoDia(bhId, data);
      if (proximaAbertura != null) {
        contados++;
        abertura = proximaAbertura;
      }
      guarda++;
    }
    if (contados < dias || abertura == null) {
      throw new CalendarioIndisponivelException(
        'Calendário "' + BUSINESS_HOURS_NAME + '" sem dias úteis suficientes.'
      );
    }
    return abertura;
  }

  /**
   * Sobrecarga para origem em DATA (ex.: data da solicitação da procuração).
   * Ancorada ao meio-dia GMT — cujo dia em São Paulo é a própria `origem`.
   */
  public static Datetime prazoEmDiasUteis(Id bhId, Date origem, Integer dias) {
    return prazoEmDiasUteis(
      bhId,
      Datetime.newInstanceGmt(origem, Time.newInstance(12, 0, 0, 0)),
      dias
    );
  }

  /**
   * (CLICKUP-9439 / CLICKUP-9429 absorvido) Quantos dias com expediente existem
   * no intervalo ABERTO NA ORIGEM e FECHADO NO DESTINO — `(origem, destino]`.
   *
   * É a régua da duração por etapa: a origem é o marco que abre a etapa e não
   * conta; o destino é o marco que a fecha e conta, se for dia útil. Logo
   * `origem == destino` devolve **0** — mesmo dia útil é etapa concluída no
   * mesmo dia, não etapa vazia. Quem consome precisa distinguir 0 de null.
   *
   * Reusa `ehDiaUtil`, que reusa `aberturaDoDia`: a régua de "este dia é útil?"
   * continua tendo UM dono só. Nenhuma grade fixa de segunda a sexta, nenhum
   * `addDays(N)` sobre o resultado, nenhum fallback silencioso.
   *
   * @throws IntervaloInvalidoException se qualquer data for nula, se `destino`
   *   for anterior a `origem`, ou se a distância passar de MAX_DIAS_INTERVALO —
   *   dado INCOERENTE, que não melhora com o tempo. Nunca devolve número
   *   negativo: intervalo invertido é exceção, não menos-um. Esta verificação
   *   vem ANTES da do calendário, de propósito: um intervalo invertido continua
   *   invertido com ou sem Business Hours, e chamá-lo de falha transitória o
   *   mandaria para uma varredura que jamais o resolveria.
   * @throws CalendarioIndisponivelException se `bhId` for nulo E o intervalo em
   *   si for válido — falha TRANSITÓRIA: o calendário pode voltar e a conta
   *   passa a ser possível.
   */
  public static Integer diasUteisEntre(Id bhId, Date origem, Date destino) {
    // A ORDEM IMPORTA: o intervalo é validado ANTES do calendário. Destino
    // anterior à origem é dado incoerente independentemente de haver Business
    // Hours — e classificar isso como "calendário indisponível" mandaria um
    // dado inválido para a varredura automática de falhas transitórias, que é
    // exatamente o retry perpétuo que a política proíbe.
    if (origem == null || destino == null) {
      throw new IntervaloInvalidoException(
        'Intervalo sem origem ou sem destino: não há o que contar.'
      );
    }
    if (destino < origem) {
      throw new IntervaloInvalidoException(
        'Destino (' +
          String.valueOf(destino) +
          ') anterior à origem (' +
          String.valueOf(origem) +
          ').'
      );
    }
    Integer distancia = origem.daysBetween(destino);
    if (distancia > MAX_DIAS_INTERVALO) {
      throw new IntervaloInvalidoException(
        'Intervalo de ' +
          String.valueOf(distancia) +
          ' dias de calendário excede o teto de ' +
          String.valueOf(MAX_DIAS_INTERVALO) +
          '.'
      );
    }
    if (bhId == null) {
      throw new CalendarioIndisponivelException(
        'Business Hours "' + BUSINESS_HOURS_NAME + '" ausente ou inativo.'
      );
    }
    Integer uteis = 0;
    Date dia = origem;
    Integer guarda = 0;
    while (dia < destino && guarda <= MAX_DIAS_INTERVALO) {
      dia = dia.addDays(1);
      if (ehDiaUtil(bhId, dia)) {
        uteis++;
      }
      guarda++;
    }
    return uteis;
  }

  /**
   * (CLICKUP-9439 / CLICKUP-9429 absorvido) Conjunto dos dias COM EXPEDIENTE no
   * intervalo fechado `[de, ate]`, calculado UMA VEZ para ser consultado em
   * memória pelo lote inteiro.
   *
   * POR QUE ESTE MÉTODO EXISTE: `aberturaDoDia` chama `BusinessHours.
   * nextStartDate` uma vez por dia avaliado. Contar dia a dia POR REGISTRO num
   * backfill de milhares de Leads com intervalos de semanas multiplica essa
   * chamada de plataforma por registro e estoura o CPU time da transação.
   * Pré-computando o intervalo GLOBAL do lote (menor origem → maior destino),
   * a chamada de plataforma acontece uma vez por dia de calendário do lote
   * inteiro, e cada registro vira consulta em memória. É o mesmo padrão que
   * `SOLCadenciaMotorService` já usa ("o mapeamento é feito PARA TRÁS, uma vez
   * por transação"), aplicado aqui à contagem para frente.
   *
   * Devolve o CONJUNTO, não a contagem: quem chama decide como indexar. O
   * consumidor de produção (SOLDuracaoEtapaService) monta um acumulado
   * ordenado sobre ESTA resposta — indexar a resposta da régua não é criar uma
   * régua paralela; nenhum outro ponto do repo decide sozinho se um dia é útil.
   *
   * @throws CalendarioIndisponivelException se `bhId` for nulo.
   * @throws IntervaloInvalidoException se alguma data for nula, se `ate` for
   *   anterior a `de`, ou se a distância passar de MAX_DIAS_INTERVALO.
   */
  public static Set<Date> diasUteisNoIntervalo(Id bhId, Date de, Date ate) {
    if (bhId == null) {
      throw new CalendarioIndisponivelException(
        'Business Hours "' + BUSINESS_HOURS_NAME + '" ausente ou inativo.'
      );
    }
    if (de == null || ate == null) {
      throw new IntervaloInvalidoException(
        'Intervalo global sem início ou sem fim: não há o que pré-computar.'
      );
    }
    if (ate < de) {
      throw new IntervaloInvalidoException(
        'Fim (' +
          String.valueOf(ate) +
          ') anterior ao início (' +
          String.valueOf(de) +
          ').'
      );
    }
    Integer distancia = de.daysBetween(ate);
    if (distancia > MAX_DIAS_INTERVALO) {
      throw new IntervaloInvalidoException(
        'Intervalo global de ' +
          String.valueOf(distancia) +
          ' dias de calendário excede o teto de ' +
          String.valueOf(MAX_DIAS_INTERVALO) +
          '.'
      );
    }
    Set<Date> uteis = new Set<Date>();
    Date dia = de;
    Integer guarda = 0;
    while (dia <= ate && guarda <= MAX_DIAS_INTERVALO) {
      if (ehDiaUtil(bhId, dia)) {
        uteis.add(dia);
      }
      dia = dia.addDays(1);
      guarda++;
    }
    return uteis;
  }
}
