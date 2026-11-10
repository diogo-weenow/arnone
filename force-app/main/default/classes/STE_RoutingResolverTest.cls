@IsTest
private class STE_RoutingResolverTest {
  private static MessagingChannel canal;

  private static MessagingChannel canalTeste() {
    if (canal == null) {
      MessagingChannel novo = new MessagingChannel(
        DeveloperName = 'STE_Canal_Teste_Resolver',
        MasterLabel = 'STE Canal Teste Resolver',
        MessageType = 'Text',
        MessagingPlatformKey = 'ste-canal-teste-resolver'
      );
      // MessagingChannel é objeto de setup: isolar a DML evita MIXED_DML_OPERATION
      // quando o teste já mexeu em Lead antes de chegar aqui.
      System.runAs(new User(Id = UserInfo.getUserId())) {
        insert novo;
      }
      canal = novo;
    }
    return canal;
  }

  private static MessagingEndUser novoEndUser(String telefone) {
    MessagingEndUser endUser = new MessagingEndUser(
      Name = 'testes resolver ' + telefone,
      MessagingChannelId = canalTeste().Id,
      MessageType = 'Text',
      MessagingPlatformKey = telefone
    );
    insert endUser;
    return endUser;
  }

  private static MessagingSession novaSessao(MessagingEndUser endUser) {
    MessagingSession sessao = new MessagingSession(
      MessagingChannelId = canalTeste().Id,
      MessagingEndUserId = endUser.Id,
      Status = 'New'
    );
    insert sessao;
    return sessao;
  }

  private static List<STE_RoutingResolver.Resultado> resolver(
    List<String> sessoes
  ) {
    List<STE_RoutingResolver.Entrada> entradas = new List<STE_RoutingResolver.Entrada>();
    for (String sessao : sessoes) {
      STE_RoutingResolver.Entrada entrada = new STE_RoutingResolver.Entrada();
      entrada.sessionId = sessao;
      entradas.add(entrada);
    }
    return STE_RoutingResolver.resolver(entradas);
  }

  private static MessagingEndUser vinculoDe(Id endUserId) {
    return [
      SELECT Id, LeadId, ContactId
      FROM MessagingEndUser
      WHERE Id = :endUserId
    ];
  }

  @IsTest
  static void passo1ResolvePelaSessaoEDevolveClassificacao() {
    MessagingEndUser endUserLead = novoEndUser('5511900000011');
    MessagingEndUser endUserContato = novoEndUser('5511900000012');
    MessagingSession sessaoLead = novaSessao(endUserLead);
    MessagingSession sessaoContato = novaSessao(endUserContato);

    Lead lead = new Lead(
      LastName = 'testes resolver quente',
      Company = 'testes resolver quente',
      Email = 'testes.resolver.quente@example.invalid',
      Status = 'Validação',
      STE_MessagingSession_Id__c = String.valueOf(sessaoLead.Id),
      STE_Classificacao_Fila__c = 'Quente',
      STE_Faixa_Etaria__c = 'De 20 a 50 anos',
      STE_Possui_CNH__c = 'Sim, envio imediato',
      STE_CNH_Enviada__c = true
    );
    insert lead;
    Contact contato = new Contact(
      LastName = 'testes resolver morno',
      Email = 'testes.resolver.morno@example.invalid',
      STE_MessagingSession_Id__c = String.valueOf(sessaoContato.Id),
      STE_Classificacao_Fila__c = 'Morna'
    );
    insert contato;

    Test.startTest();
    List<STE_RoutingResolver.Resultado> r = resolver(
      new List<String>{
        String.valueOf(sessaoLead.Id),
        String.valueOf(sessaoContato.Id),
        'invalida'
      }
    );
    Test.stopTest();

    Assert.areEqual(3, r.size());

    Assert.isTrue(r[0].encontrado);
    Assert.areEqual('Sessao', r[0].origemMatch);
    Assert.areEqual('Quente', r[0].classificacao);
    Assert.areEqual(String.valueOf(lead.Id), r[0].recordId);
    Assert.areEqual('Lead', r[0].tipoRegistro);
    Assert.areEqual('Validação', r[0].statusLead);
    Assert.areEqual('De 20 a 50 anos', r[0].faixaEtaria);
    Assert.areEqual('Sim, envio imediato', r[0].possuiCnh);
    Assert.isTrue(r[0].cnhEnviada);

    Assert.isTrue(r[1].encontrado);
    Assert.areEqual('Sessao', r[1].origemMatch);
    Assert.areEqual('Morna', r[1].classificacao);
    Assert.areEqual('Contact', r[1].tipoRegistro);

    Assert.isFalse(r[2].encontrado);
    Assert.isNull(r[2].classificacao);
  }

  @IsTest
  static void passo2ResolvePeloVinculoEDevolveClassificacao() {
    MessagingEndUser endUser = novoEndUser('5511900000013');
    Lead anterior = new Lead(
      LastName = 'testes resolver vinculo',
      Company = 'testes resolver vinculo',
      Email = 'testes.resolver.vinculo@example.invalid',
      Status = 'Validação',
      STE_Classificacao_Fila__c = 'Quente'
    );
    insert anterior;
    update new MessagingEndUser(Id = endUser.Id, LeadId = anterior.Id);

    MessagingSession nova = novaSessao(endUser);

    Test.startTest();
    List<STE_RoutingResolver.Resultado> r = resolver(
      new List<String>{ String.valueOf(nova.Id) }
    );
    Test.stopTest();

    Assert.isTrue(r[0].encontrado, 'O vínculo do telefone deve reconhecer.');
    Assert.areEqual('Vinculo', r[0].origemMatch);
    Assert.areEqual(String.valueOf(anterior.Id), r[0].recordId);
    Assert.areEqual('Lead', r[0].tipoRegistro);
    Assert.areEqual(
      'Quente',
      r[0].classificacao,
      'Quem volta com o cadastro qualificado vai direto para a fila.'
    );
  }

  @IsTest
  static void passo2DaPrecedenciaAoContato() {
    MessagingEndUser endUser = novoEndUser('5511900000014');
    Contact contato = new Contact(
      LastName = 'testes resolver contato vinculo',
      Email = 'testes.resolver.contato.vinculo@example.invalid',
      STE_Classificacao_Fila__c = 'Quente'
    );
    insert contato;
    update new MessagingEndUser(Id = endUser.Id, ContactId = contato.Id);

    MessagingSession nova = novaSessao(endUser);

    Test.startTest();
    List<STE_RoutingResolver.Resultado> r = resolver(
      new List<String>{ String.valueOf(nova.Id) }
    );
    Test.stopTest();

    Assert.areEqual('Vinculo', r[0].origemMatch);
    Assert.areEqual('Contact', r[0].tipoRegistro);
    Assert.areEqual(String.valueOf(contato.Id), r[0].recordId);
  }

  @IsTest
  static void passo3ResolvePeloTelefoneEGravaOVinculo() {
    MessagingEndUser endUser = novoEndUser('5511900000015');
    Lead lead = new Lead(
      LastName = 'testes resolver telefone',
      Company = 'testes resolver telefone',
      Email = 'testes.resolver.telefone@example.invalid',
      Status = 'Validação',
      STE_Telefone_E164__c = '5511900000015'
    );
    insert lead;

    MessagingSession nova = novaSessao(endUser);
    Assert.isNull(vinculoDe(endUser.Id).LeadId);

    Test.startTest();
    List<STE_RoutingResolver.Resultado> r = resolver(
      new List<String>{ String.valueOf(nova.Id) }
    );
    Test.stopTest();

    Assert.isTrue(r[0].encontrado);
    Assert.areEqual('Telefone', r[0].origemMatch);
    Assert.areEqual(String.valueOf(lead.Id), r[0].recordId);
    Assert.isNull(r[0].classificacao);
    Assert.areEqual(
      lead.Id,
      vinculoDe(endUser.Id).LeadId,
      'O match por telefone deve gravar o vínculo para a próxima conversa.'
    );
  }

  @IsTest
  static void passo3CasaTelefoneSemONonoDigito() {
    MessagingEndUser endUser = novoEndUser('5511987654321');
    Lead antigo = new Lead(
      LastName = 'testes resolver oito digitos',
      Company = 'testes resolver oito digitos',
      Email = 'testes.resolver.oito@example.invalid',
      Status = 'Novo',
      STE_Telefone_E164__c = '551187654321'
    );
    insert antigo;

    MessagingSession nova = novaSessao(endUser);

    Test.startTest();
    List<STE_RoutingResolver.Resultado> r = resolver(
      new List<String>{ String.valueOf(nova.Id) }
    );
    Test.stopTest();

    Assert.isTrue(
      r[0].encontrado,
      'Registro antigo com 8 dígitos deve casar com o WhatsApp de 9 dígitos.'
    );
    Assert.areEqual('Telefone', r[0].origemMatch);
    Assert.areEqual(String.valueOf(antigo.Id), r[0].recordId);
  }

  @IsTest
  static void vinculoComFriaNaoDevolveClassificacao() {
    MessagingEndUser endUser = novoEndUser('5511900000017');
    Lead recusado = new Lead(
      LastName = 'testes resolver fria',
      Company = 'testes resolver fria',
      Email = 'testes.resolver.fria@example.invalid',
      Status = 'Validação',
      STE_Classificacao_Fila__c = 'Fria'
    );
    insert recusado;
    update new MessagingEndUser(Id = endUser.Id, LeadId = recusado.Id);

    MessagingSession nova = novaSessao(endUser);

    Test.startTest();
    List<STE_RoutingResolver.Resultado> r = resolver(
      new List<String>{ String.valueOf(nova.Id) }
    );
    Test.stopTest();

    Assert.isTrue(r[0].encontrado, 'O candidato recusado continua sendo reconhecido.');
    Assert.areEqual(String.valueOf(recusado.Id), r[0].recordId);
    Assert.isNull(
      r[0].classificacao,
      'Fria fora da conversa atual volta ao bot, que dá a devolutiva e encerra.'
    );
  }

  @IsTest
  static void telefoneComCadastroQualificadoDevolveClassificacao() {
    MessagingEndUser endUser = novoEndUser('5511900000018');
    Lead anterior = new Lead(
      LastName = 'testes resolver telefone morna',
      Company = 'testes resolver telefone morna',
      Email = 'testes.resolver.telefone.morna@example.invalid',
      Status = 'Validação',
      STE_Telefone_E164__c = '5511900000018',
      STE_Classificacao_Fila__c = 'Morna'
    );
    insert anterior;

    MessagingSession nova = novaSessao(endUser);

    Test.startTest();
    List<STE_RoutingResolver.Resultado> r = resolver(
      new List<String>{ String.valueOf(nova.Id) }
    );
    Test.stopTest();

    Assert.areEqual('Telefone', r[0].origemMatch);
    Assert.areEqual('Morna', r[0].classificacao);
  }

  @IsTest
  static void naoEncontraQuandoNaoHaCandidato() {
    MessagingEndUser endUser = novoEndUser('5511900000016');
    MessagingSession nova = novaSessao(endUser);

    Test.startTest();
    List<STE_RoutingResolver.Resultado> r = resolver(
      new List<String>{ String.valueOf(nova.Id) }
    );
    Test.stopTest();

    Assert.isFalse(r[0].encontrado);
    Assert.isNull(r[0].recordId);
    Assert.isNull(r[0].classificacao);
    Assert.isNull(vinculoDe(endUser.Id).LeadId);
  }

  @IsTest
  static void ignoraLeadConvertidoESessaoInexistente() {
    MessagingEndUser endUser = novoEndUser('5511900000017');
    MessagingSession nova = novaSessao(endUser);

    Test.startTest();
    List<STE_RoutingResolver.Resultado> r = resolver(
      new List<String>{ '0Mw000000000099', String.valueOf(nova.Id) }
    );
    Test.stopTest();

    Assert.isFalse(
      r[0].encontrado,
      'Sessão que não existe na org não pode resolver candidato.'
    );
    Assert.isFalse(r[1].encontrado);
  }

  @IsTest
  static void aceitaListaNulaEEntradaVazia() {
    Assert.areEqual(0, STE_RoutingResolver.resolver(null).size());

    List<STE_RoutingResolver.Resultado> r = STE_RoutingResolver.resolver(
      new List<STE_RoutingResolver.Entrada>{
        new STE_RoutingResolver.Entrada()
      }
    );
    Assert.areEqual(1, r.size());
    Assert.isFalse(r[0].encontrado);
    Assert.isNull(r[0].recordId);
  }
}