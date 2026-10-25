@IsTest
private class STE_BotRegistrarEtapaTest {
  private static MessagingChannel canalTeste;

  private static MessagingEndUser novoEndUser(String telefone) {
    return novoEndUser(telefone, null);
  }

  private static MessagingEndUser novoEndUser(String telefone, Id leadId) {
    if (canalTeste == null) {
      canalTeste = new MessagingChannel(
        DeveloperName = 'STE_Canal_Teste_Etapa',
        MasterLabel = 'STE Canal Teste Etapa',
        MessageType = 'Text',
        MessagingPlatformKey = 'ste-canal-teste-etapa'
      );
      // MessagingChannel é objeto de setup: precisa de transação separada
      // do Lead e do MessagingEndUser, senão dá MIXED_DML_OPERATION.
      System.runAs(new User(Id = UserInfo.getUserId())) {
        insert canalTeste;
      }
    }
    MessagingEndUser endUser = new MessagingEndUser(
      Name = 'testes etapa ' + telefone,
      MessagingChannelId = canalTeste.Id,
      MessageType = 'Text',
      MessagingPlatformKey = telefone
    );
    if (leadId != null) {
      endUser.LeadId = leadId;
    }
    insert endUser;
    return endUser;
  }

  private static Lead novoLead(String telefone) {
    Lead l = new Lead(
      LastName = 'testes etapa candidato',
      Company = 'testes etapa candidato',
      STE_Telefone_E164__c = telefone
    );
    insert l;
    return l;
  }

  private static STE_BotRegistrarEtapa.Entrada entrada(
    String etapa,
    Id endUserId
  ) {
    STE_BotRegistrarEtapa.Entrada e = new STE_BotRegistrarEtapa.Entrada();
    e.etapa = etapa;
    e.endUserId = endUserId;
    return e;
  }

  @IsTest
  static void gravaEtapaNoLeadEncontradoPeloTelefone() {
    String telefone = '5511900000001';
    Lead l = novoLead(telefone);
    MessagingEndUser eu = novoEndUser(telefone);

    Test.startTest();
    List<STE_BotRegistrarEtapa.Resultado> r = STE_BotRegistrarEtapa.registrar(
      new List<STE_BotRegistrarEtapa.Entrada>{
        entrada('Aguardando e-mail', eu.Id)
      }
    );
    Test.stopTest();

    Assert.isTrue(r[0].gravado, 'A etapa deveria ter sido gravada.');
    Assert.areEqual(String.valueOf(l.Id), r[0].recordId);

    Lead gravado = [
      SELECT STE_Etapa_Bot__c, STE_Etapa_Bot_Desde__c
      FROM Lead
      WHERE Id = :l.Id
    ];
    Assert.areEqual('Aguardando e-mail', gravado.STE_Etapa_Bot__c);
    Assert.isNotNull(
      gravado.STE_Etapa_Bot_Desde__c,
      'O momento da etapa precisa ficar registrado.'
    );
  }

  @IsTest
  static void gravaEtapaNoLeadJaVinculadoAoEndUser() {
    Lead l = novoLead('5511900000002');
    // O telefone do end user é outro de propósito: só o vínculo direto
    // com o Lead pode encontrá-lo.
    MessagingEndUser eu = novoEndUser('5511999999999', l.Id);

    Test.startTest();
    List<STE_BotRegistrarEtapa.Resultado> r = STE_BotRegistrarEtapa.registrar(
      new List<STE_BotRegistrarEtapa.Entrada>{
        entrada('Aguardando escolha da CNH', eu.Id)
      }
    );
    Test.stopTest();

    Assert.isTrue(r[0].gravado, 'O vínculo do end user deveria achar o Lead.');
    Lead gravado = [
      SELECT STE_Etapa_Bot__c
      FROM Lead
      WHERE Id = :l.Id
    ];
    Assert.areEqual('Aguardando escolha da CNH', gravado.STE_Etapa_Bot__c);
  }

  @IsTest
  static void avancaDeUmaEtapaParaOutra() {
    String telefone = '5511900000003';
    Lead l = novoLead(telefone);
    MessagingEndUser eu = novoEndUser(telefone);

    Test.startTest();
    STE_BotRegistrarEtapa.registrar(
      new List<STE_BotRegistrarEtapa.Entrada>{
        entrada('Aguardando e-mail', eu.Id)
      }
    );
    STE_BotRegistrarEtapa.registrar(
      new List<STE_BotRegistrarEtapa.Entrada>{
        entrada('Aguardando faixa etária', eu.Id)
      }
    );
    Test.stopTest();

    Lead gravado = [
      SELECT STE_Etapa_Bot__c
      FROM Lead
      WHERE Id = :l.Id
    ];
    Assert.areEqual(
      'Aguardando faixa etária',
      gravado.STE_Etapa_Bot__c,
      'A etapa precisa refletir a pergunta mais recente.'
    );
  }

  @IsTest
  static void naoFalhaQuandoNaoExisteLead() {
    MessagingEndUser eu = novoEndUser('5511900000004');

    Test.startTest();
    List<STE_BotRegistrarEtapa.Resultado> r = STE_BotRegistrarEtapa.registrar(
      new List<STE_BotRegistrarEtapa.Entrada>{
        entrada('Aguardando nome', eu.Id)
      }
    );
    Test.stopTest();

    Assert.isFalse(
      r[0].gravado,
      'Sem Lead não há onde gravar, mas a conversa não pode quebrar.'
    );
    Assert.isNull(r[0].recordId);
  }

  @IsTest
  static void ignoraContextoInvalidoSemQuebrar() {
    STE_BotRegistrarEtapa.Entrada semEndUser = new STE_BotRegistrarEtapa.Entrada();
    semEndUser.etapa = 'Aguardando nome';

    STE_BotRegistrarEtapa.Entrada idEstranho = new STE_BotRegistrarEtapa.Entrada();
    idEstranho.etapa = 'Aguardando nome';
    idEstranho.endUserId = 'nao é um id';

    Test.startTest();
    List<STE_BotRegistrarEtapa.Resultado> r = STE_BotRegistrarEtapa.registrar(
      new List<STE_BotRegistrarEtapa.Entrada>{ semEndUser, idEstranho }
    );
    Test.stopTest();

    Assert.areEqual(2, r.size());
    Assert.isFalse(r[0].gravado);
    Assert.isFalse(r[1].gravado);
  }

  @IsTest
  static void ignoraEtapaEmBranco() {
    String telefone = '5511900000005';
    novoLead(telefone);
    MessagingEndUser eu = novoEndUser(telefone);

    Test.startTest();
    List<STE_BotRegistrarEtapa.Resultado> r = STE_BotRegistrarEtapa.registrar(
      new List<STE_BotRegistrarEtapa.Entrada>{ entrada('   ', eu.Id) }
    );
    Test.stopTest();

    Assert.isFalse(r[0].gravado, 'Etapa em branco não deve gravar nada.');
  }

  @IsTest
  static void aceitaListaVaziaOuNula() {
    Test.startTest();
    Assert.areEqual(
      0,
      STE_BotRegistrarEtapa.registrar(null).size()
    );
    Assert.areEqual(
      0,
      STE_BotRegistrarEtapa.registrar(
          new List<STE_BotRegistrarEtapa.Entrada>()
        )
        .size()
    );
    Test.stopTest();
  }

  @IsTest
  static void agendaAChamadaEmHorasUteis() {
    String telefone = '5511900000006';
    Lead l = novoLead(telefone);
    MessagingEndUser eu = novoEndUser(telefone);

    Test.startTest();
    STE_BotRegistrarEtapa.registrar(
      new List<STE_BotRegistrarEtapa.Entrada>{
        entrada('Aguardando e-mail', eu.Id)
      }
    );
    Test.stopTest();

    Lead gravado = [
      SELECT STE_Etapa_Bot_Desde__c, STE_Retomada_1_Em__c
      FROM Lead
      WHERE Id = :l.Id
    ];

    List<BusinessHours> horario = [
      SELECT Id
      FROM BusinessHours
      WHERE Name = 'Stech - Business Hours' AND IsActive = TRUE
      LIMIT 1
    ];
    if (horario.isEmpty()) {
      // Sem o horário configurado a classe não agenda, e isso é proposital.
      Assert.isNull(gravado.STE_Retomada_1_Em__c);
      return;
    }

    Assert.isNotNull(gravado.STE_Retomada_1_Em__c);
    Assert.isTrue(
      gravado.STE_Retomada_1_Em__c >= gravado.STE_Etapa_Bot_Desde__c,
      'A chamada não pode ser marcada para antes da resposta.'
    );
    Assert.isTrue(
      BusinessHours.isWithin(horario[0].Id, gravado.STE_Retomada_1_Em__c),
      'A chamada tem de cair dentro do horário comercial.'
    );
  }

  @IsTest
  static void recalculaOAgendamentoQuandoOCandidatoResponde() {
    String telefone = '5511900000007';
    Lead l = novoLead(telefone);
    MessagingEndUser eu = novoEndUser(telefone);

    Test.startTest();
    STE_BotRegistrarEtapa.registrar(
      new List<STE_BotRegistrarEtapa.Entrada>{
        entrada('Aguardando e-mail', eu.Id)
      }
    );
    Datetime primeiro = [
      SELECT STE_Retomada_1_Em__c
      FROM Lead
      WHERE Id = :l.Id
    ]
    .STE_Retomada_1_Em__c;

    STE_BotRegistrarEtapa.registrar(
      new List<STE_BotRegistrarEtapa.Entrada>{
        entrada('Aguardando faixa etária', eu.Id)
      }
    );
    Test.stopTest();

    Datetime depois = [
      SELECT STE_Retomada_1_Em__c
      FROM Lead
      WHERE Id = :l.Id
    ]
    .STE_Retomada_1_Em__c;

    if (primeiro == null) {
      return;
    }
    Assert.isTrue(
      depois >= primeiro,
      'Ao responder de novo, o relógio da retomada precisa ser refeito.'
    );
  }
}