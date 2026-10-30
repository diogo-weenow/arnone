@IsTest
private class STE_BotConsultarCandidatoTest {
  private static MessagingChannel canalTeste;

  private static MessagingEndUser novoEndUser(String telefone) {
    if (canalTeste == null) {
      MessagingChannel canal = new MessagingChannel(
        DeveloperName = 'STE_Canal_Teste_Consulta',
        MasterLabel = 'STE Canal Teste Consulta',
        MessageType = 'Text',
        MessagingPlatformKey = 'ste-canal-teste-consulta'
      );
      // MessagingChannel é objeto de setup: isolar a DML evita
      // MIXED_DML_OPERATION quando o teste já mexeu em Lead antes.
      System.runAs(new User(Id = UserInfo.getUserId())) {
        insert canal;
      }
      canalTeste = canal;
    }
    MessagingEndUser endUser = new MessagingEndUser(
      Name = 'testes consulta ' + telefone,
      MessagingChannelId = canalTeste.Id,
      MessageType = 'Text',
      MessagingPlatformKey = telefone
    );
    insert endUser;
    return endUser;
  }

  private static List<STE_BotConsultarCandidato.Resultado> consultar(
    String endUserId
  ) {
    STE_BotConsultarCandidato.Entrada e = new STE_BotConsultarCandidato.Entrada();
    e.endUserId = endUserId;
    return STE_BotConsultarCandidato.consultar(
      new List<STE_BotConsultarCandidato.Entrada>{ e }
    );
  }

  @IsTest
  static void achaLeadPeloTelefoneDaConversa() {
    Lead l = new Lead(
      LastName = 'testes consulta lead',
      Company = 'testes consulta lead',
      Email = 'testes.consulta.lead@example.invalid',
      MobilePhone = '+5511999990001',
      STE_Genero__c = 'Masculino',
      STE_Telefone_E164__c = '5511999990001'
    );
    insert l;
    MessagingEndUser eu = novoEndUser('5511999990001');

    Test.startTest();
    List<STE_BotConsultarCandidato.Resultado> r = consultar(eu.Id);
    Test.stopTest();

    Assert.isTrue(r[0].encontrado, 'deveria achar o lead pelo telefone');
    Assert.areEqual('Lead', r[0].tipoRegistro);
    Assert.areEqual(l.Id, (Id) r[0].recordId);
    Assert.areEqual('testes consulta lead', r[0].nome);
    Assert.areEqual('Masculino', r[0].genero);
    Assert.isTrue(
      r[0].resumo.contains('testes.consulta.lead@example.invalid'),
      'o resumo deveria trazer o e-mail: ' + r[0].resumo
    );
  }

  @IsTest
  static void achaContatoPeloVinculoAntesDoLead() {
    Contact c = new Contact(
      LastName = 'testes consulta contato',
      Email = 'testes.consulta.contato@example.invalid',
      MobilePhone = '+5511999990002',
      STE_Genero__c = 'Feminino',
      STE_Telefone_E164__c = '5511999990002'
    );
    insert c;
    Lead l = new Lead(
      LastName = 'testes consulta lead rival',
      Company = 'testes consulta lead rival',
      STE_Telefone_E164__c = '5511999990002'
    );
    insert l;
    MessagingEndUser eu = novoEndUser('5511999990002');
    update new MessagingEndUser(Id = eu.Id, ContactId = c.Id);

    Test.startTest();
    List<STE_BotConsultarCandidato.Resultado> r = consultar(eu.Id);
    Test.stopTest();

    Assert.areEqual('Contact', r[0].tipoRegistro, 'contato tem precedência');
    Assert.areEqual(c.Id, (Id) r[0].recordId);
  }

  @IsTest
  static void casaTelefoneSemNonoDigito() {
    Lead l = new Lead(
      LastName = 'testes consulta oito digitos',
      Company = 'testes consulta oito digitos',
      STE_Telefone_E164__c = '551133330003'
    );
    insert l;
    MessagingEndUser eu = novoEndUser('5511933330003');

    Test.startTest();
    List<STE_BotConsultarCandidato.Resultado> r = consultar(eu.Id);
    Test.stopTest();

    Assert.isTrue(r[0].encontrado, 'deveria casar com e sem o nono dígito');
    Assert.areEqual(l.Id, (Id) r[0].recordId);
  }

  @IsTest
  static void ignoraLeadConvertido() {
    MessagingEndUser eu = novoEndUser('5511999990004');

    Test.startTest();
    List<STE_BotConsultarCandidato.Resultado> r = consultar(eu.Id);
    Test.stopTest();

    Assert.isFalse(r[0].encontrado, 'sem cadastro não deveria achar nada');
    Assert.areEqual('', r[0].resumo);
  }

  @IsTest
  static void mostraNumeroDoWhatsAppQuandoNaoHaTelefoneDeContato() {
    Lead l = new Lead(
      LastName = 'testes consulta sem mobile',
      Company = 'testes consulta sem mobile',
      STE_Telefone_E164__c = '5511999990005'
    );
    insert l;
    MessagingEndUser eu = novoEndUser('5511999990005');

    Test.startTest();
    List<STE_BotConsultarCandidato.Resultado> r = consultar(eu.Id);
    Test.stopTest();

    Assert.areEqual('+5511999990005', r[0].telefone);
    Assert.isTrue(
      r[0].resumo.contains('não informado'),
      'e-mail e gênero vazios deveriam aparecer como não informado: ' +
      r[0].resumo
    );
  }

  @IsTest
  static void cadastroSemEmailNaoVaiParaConfirmacao() {
    Lead l = new Lead(
      LastName = 'testes consulta sem email',
      Company = 'testes consulta sem email',
      MobilePhone = '+5511999990006',
      STE_Telefone_E164__c = '5511999990006'
    );
    insert l;
    MessagingEndUser eu = novoEndUser('5511999990006');

    Test.startTest();
    List<STE_BotConsultarCandidato.Resultado> r = consultar(eu.Id);
    Test.stopTest();

    Assert.isTrue(r[0].encontrado, 'o cadastro existe');
    Assert.isFalse(
      r[0].podeConfirmar,
      'sem e-mail não dá para confirmar: o registro final exige o e-mail'
    );
  }

  @IsTest
  static void cadastroComEmailVaiParaConfirmacao() {
    Lead l = new Lead(
      LastName = 'testes consulta com email',
      Company = 'testes consulta com email',
      Email = 'testes.com.email@example.invalid',
      STE_Telefone_E164__c = '5511999990007'
    );
    insert l;
    MessagingEndUser eu = novoEndUser('5511999990007');

    Test.startTest();
    List<STE_BotConsultarCandidato.Resultado> r = consultar(eu.Id);
    Test.stopTest();

    Assert.isTrue(r[0].podeConfirmar, 'com e-mail dá para confirmar');
  }

  @IsTest
  static void devolveVazioParaEntradaInvalida() {
    Test.startTest();
    List<STE_BotConsultarCandidato.Resultado> semNada = STE_BotConsultarCandidato.consultar(
      new List<STE_BotConsultarCandidato.Entrada>()
    );
    List<STE_BotConsultarCandidato.Resultado> comLixo = consultar('não é um id');
    Test.stopTest();

    Assert.isTrue(semNada.isEmpty(), 'lista vazia não devolve resultado');
    Assert.isFalse(comLixo[0].encontrado, 'id inválido não acha ninguém');
  }
}