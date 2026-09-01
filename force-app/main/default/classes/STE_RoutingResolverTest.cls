@IsTest
private class STE_RoutingResolverTest {
  private static final String SESSAO_LEAD = '0Mw000000000011';
  private static final String SESSAO_CONTATO = '0Mw000000000012';

  @IsTest
  static void resolveLeadContatoEEntradaInvalida() {
    String sessaoLead = String.valueOf((Id) SESSAO_LEAD);
    String sessaoContato = String.valueOf((Id) SESSAO_CONTATO);
    Lead lead = new Lead(
      LastName = 'testes resolver quente',
      Company = 'testes resolver quente',
      Email = 'testes.resolver.quente@example.invalid',
      Status = 'Novo',
      STE_MessagingSession_Id__c = sessaoLead,
      STE_Classificacao_Fila__c = 'Quente'
    );
    insert lead;
    Contact contato = new Contact(
      LastName = 'testes resolver morno',
      Email = 'testes.resolver.morno@example.invalid',
      STE_MessagingSession_Id__c = sessaoContato,
      STE_Classificacao_Fila__c = 'Morna'
    );
    insert contato;

    List<STE_RoutingResolver.Entrada> entradas = new List<STE_RoutingResolver.Entrada>();
    for (
      String sessao : new List<String>{ sessaoLead, sessaoContato, 'invalida' }
    ) {
      STE_RoutingResolver.Entrada entrada = new STE_RoutingResolver.Entrada();
      entrada.sessionId = sessao;
      entradas.add(entrada);
    }

    Test.startTest();
    List<STE_RoutingResolver.Resultado> resultados = STE_RoutingResolver.resolver(
      entradas
    );
    Test.stopTest();

    Assert.areEqual(3, resultados.size());
    Assert.areEqual('Quente', resultados[0].classificacao);
    Assert.areEqual(String.valueOf(lead.Id), resultados[0].recordId);
    Assert.areEqual('Lead', resultados[0].tipoRegistro);
    Assert.areEqual('Morna', resultados[1].classificacao);
    Assert.areEqual(String.valueOf(contato.Id), resultados[1].recordId);
    Assert.areEqual('Contact', resultados[1].tipoRegistro);
    Assert.isNull(resultados[2].classificacao);
  }

  @IsTest
  static void aceitaListaNula() {
    Assert.areEqual(0, STE_RoutingResolver.resolver(null).size());
  }
}