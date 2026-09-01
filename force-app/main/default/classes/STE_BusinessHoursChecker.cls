public with sharing class STE_BusinessHoursChecker {
    private static final String BUSINESS_HOURS_NAME = 'Stech - Business Hours';

    @TestVisible
    private static Datetime currentTimeOverride;

    public class Request {
        @InvocableVariable(label='Contexto')
        public String context;
    }

    public class Response {
        @InvocableVariable(label='Está dentro do horário comercial')
        public Boolean isWithinBusinessHours;
    }

    @InvocableMethod(
        label='Verificar horário comercial STech'
        description='Consulta o Business Hours STech e informa se o momento atual está dentro do expediente.'
    )
    public static List<Response> checkBusinessHours(List<Request> requests) {
        List<Response> responses = new List<Response>();
        List<BusinessHours> configuredHours = [
            SELECT Id, TimeZoneSidKey
            FROM BusinessHours
            WHERE Name = :BUSINESS_HOURS_NAME
                AND IsActive = true
            LIMIT 1
        ];

        Datetime instant = currentTimeOverride == null ? Datetime.now() : currentTimeOverride;
        Boolean isWithinConfiguredHours = false;

        if (!configuredHours.isEmpty()) {
            BusinessHours stechHours = configuredHours[0];
            isWithinConfiguredHours = !isWeekend(instant, stechHours.TimeZoneSidKey)
                && BusinessHours.isWithin(stechHours.Id, instant);
        }

        for (Request ignored : requests) {
            Response response = new Response();
            response.isWithinBusinessHours = isWithinConfiguredHours;
            responses.add(response);
        }

        return responses;
    }

    private static Boolean isWeekend(Datetime instant, String timeZoneSidKey) {
        Date localDate = Date.valueOf(instant.format('yyyy-MM-dd', timeZoneSidKey));
        Integer daysSinceMonday = Date.newInstance(1900, 1, 1).daysBetween(localDate);
        Integer dayOfWeek = Math.mod(daysSinceMonday, 7);
        return dayOfWeek == 5 || dayOfWeek == 6;
    }
}