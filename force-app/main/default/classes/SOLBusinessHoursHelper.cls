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
      // Instante seguramente ANTERIOR à abertura de `data` em São Paulo
      // (00:00 UTC de `data` = véspera à noite em SP, sempre fora de expediente).
      Datetime antesDaAbertura = Datetime.newInstanceGmt(
        data,
        Time.newInstance(0, 0, 0, 0)
      );
      Datetime proximaAbertura = BusinessHours.nextStartDate(bhId, antesDaAbertura);
      if (proximaAbertura != null && dataEm(proximaAbertura, TZ_SAO_PAULO) == data) {
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
}
