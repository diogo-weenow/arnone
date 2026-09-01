@IsTest(SeeAllData=true)
private class STE_BusinessHoursCheckerTest {
    @IsTest
    static void returnsTrueDuringConfiguredWeekdayHours() {
        // Segunda-feira, exatamente às 08h no fuso do Business Hours (UTC-3).
        STE_BusinessHoursChecker.currentTimeOverride = Datetime.newInstanceGMT(2026, 8, 17, 11, 0, 0);

        Test.startTest();
        List<STE_BusinessHoursChecker.Response> results =
            STE_BusinessHoursChecker.checkBusinessHours(
                new List<STE_BusinessHoursChecker.Request>{ new STE_BusinessHoursChecker.Request() }
            );
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(true, results[0].isWithinBusinessHours);
    }

    @IsTest
    static void returnsFalseOnWeekend() {
        STE_BusinessHoursChecker.currentTimeOverride = Datetime.newInstanceGMT(2026, 8, 22, 13, 0, 0);

        Test.startTest();
        List<STE_BusinessHoursChecker.Response> results =
            STE_BusinessHoursChecker.checkBusinessHours(
                new List<STE_BusinessHoursChecker.Request>{ new STE_BusinessHoursChecker.Request() }
            );
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(false, results[0].isWithinBusinessHours);
    }

    @IsTest
    static void returnsTrueBeforeFridayClosingTime() {
        STE_BusinessHoursChecker.currentTimeOverride = Datetime.newInstanceGMT(2026, 8, 21, 19, 0, 0);

        List<STE_BusinessHoursChecker.Response> results =
            STE_BusinessHoursChecker.checkBusinessHours(
                new List<STE_BusinessHoursChecker.Request>{ new STE_BusinessHoursChecker.Request() }
            );

        System.assertEquals(true, results[0].isWithinBusinessHours);
    }

    @IsTest
    static void returnsFalseAfterFridayClosingTime() {
        // Sexta-feira, exatamente às 17h no fuso do Business Hours (UTC-3).
        STE_BusinessHoursChecker.currentTimeOverride = Datetime.newInstanceGMT(2026, 8, 21, 20, 0, 0);

        List<STE_BusinessHoursChecker.Response> results =
            STE_BusinessHoursChecker.checkBusinessHours(
                new List<STE_BusinessHoursChecker.Request>{ new STE_BusinessHoursChecker.Request() }
            );

        System.assertEquals(false, results[0].isWithinBusinessHours);
    }
}