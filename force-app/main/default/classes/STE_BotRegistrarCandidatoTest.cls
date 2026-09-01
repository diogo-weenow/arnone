@IsTest
private class STE_BotRegistrarCandidatoTest {
  private static final String SESSAO_TESTE = '0Mw000000000001';

  private static STE_BotRegistrarCandidato.Entrada entrada(
    String email,
    String idade,
    String cnh,
    String trabalhou,
    String empresa
  ) {
    STE_BotRegistrarCandidato.Entrada e = new STE_BotRegistrarCandidato.Entrada();
    e.email = email;
    e.nomeCompleto = 'testes candidato bot';
    e.respostaPreInscricao = 'Sim, vamos lá!';
    e.respostaIdade = idade;
    e.jaTrabalhouTelecom = trabalhou;
    e.empresaTelecomAnterior = empresa;
    e.respostaCNH = cnh;
    e.routableId = SESSAO_TESTE;
    return e;
  }

  @IsTest
  static void criaLeadQuenteSemValidarCnh() {
    Test.startTest();
    List<STE_BotRegistrarCandidato.Resultado> r = STE_BotRegistrarCandidato.registrar(
      new List<STE_BotRegistrarCandidato.Entrada>{
        entrada(
          'testes.bot.quente@example.invalid',
          'Sim',
          'Vou enviar agora',
          'Sim',
          'testes Parceira A'
        )
      }
    );
    Test.stopTest();

    Assert.isTrue(r[0].sucesso, r[0].mensagem);
    Assert.areEqual('Lead', r[0].tipoRegistro);
    Lead l = [
      SELECT
        RecordType.DeveloperName,
        Status,
        STE_CNH_Enviada__c,
        STE_Classificacao_Fila__c,
        STE_Faixa_Etaria__c,
        STE_Possui_CNH__c,
        STE_Interesse_Pre_Inscricao__c,
        STE_Ja_Trabalhou_Telecom__c,
        STE_Empresa_Telecom_Anterior__c,
        STE_MessagingSession_Id__c
      FROM Lead
      WHERE Id = :r[0].recordId
    ];
    Assert.areEqual('STE', l.RecordType.DeveloperName);
    Assert.areEqual('Validação', l.Status);
    Assert.isFalse(
      l.STE_CNH_Enviada__c,
      'O atendente é quem valida o recebimento da CNH.'
    );
    Assert.areEqual('Quente', l.STE_Classificacao_Fila__c);
    Assert.areEqual('De 20 a 50 anos', l.STE_Faixa_Etaria__c);
    Assert.areEqual('Sim, envio imediato', l.STE_Possui_CNH__c);
    Assert.areEqual('Sim, vamos lá!', l.STE_Interesse_Pre_Inscricao__c);
    Assert.areEqual('Sim', l.STE_Ja_Trabalhou_Telecom__c);
    Assert.areEqual('testes Parceira A', l.STE_Empresa_Telecom_Anterior__c);
    Assert.areEqual(
      String.valueOf((Id) SESSAO_TESTE),
      l.STE_MessagingSession_Id__c
    );
  }

  @IsTest
  static void criaLeadQuenteQuandoSessaoPossuiAnexo() {
    STE_BotRegistrarCandidato.Entrada e = entrada(
      'testes.bot.anexo.quente@example.invalid',
      'Sim',
      null,
      'NÃ£o',
      null
    );
    STE_BotRegistrarCandidato.sessoesComAnexoTeste = new Set<Id>{
      (Id) SESSAO_TESTE
    };

    Test.startTest();
    List<STE_BotRegistrarCandidato.Resultado> r = STE_BotRegistrarCandidato.registrar(
      new List<STE_BotRegistrarCandidato.Entrada>{ e }
    );
    Test.stopTest();

    Assert.isTrue(r[0].sucesso, r[0].mensagem);
    Lead l = [
      SELECT STE_Classificacao_Fila__c, STE_Possui_CNH__c
      FROM Lead
      WHERE Id = :r[0].recordId
    ];
    Assert.areEqual('Quente', l.STE_Classificacao_Fila__c);
    Assert.areEqual('Sim, envio imediato', l.STE_Possui_CNH__c);
  }

  @IsTest
  static void anexoPrevaleceSobreValorNaoReconhecidoDoBot() {
    STE_BotRegistrarCandidato.Entrada e = entrada(
      'testes.anexo.prevalece@example.invalid',
      'Sim',
      'valor interno do componente de anexo',
      'Não',
      null
    );
    e.routableId = '0Mw000000000003';
    STE_BotRegistrarCandidato.sessoesComAnexoTeste = new Set<Id>{
      (Id) e.routableId
    };

    Test.startTest();
    List<STE_BotRegistrarCandidato.Resultado> resultados = STE_BotRegistrarCandidato.registrar(
      new List<STE_BotRegistrarCandidato.Entrada>{ e }
    );
    Test.stopTest();

    Lead l = [
      SELECT STE_Classificacao_Fila__c, STE_Possui_CNH__c
      FROM Lead
      WHERE Id = :resultados[0].recordId
    ];
    Assert.areEqual('Quente', l.STE_Classificacao_Fila__c);
    Assert.areEqual('Sim, envio imediato', l.STE_Possui_CNH__c);
  }

  @IsTest
  static void atualizaLeadMornoSemDuplicar() {
    Lead existente = new Lead(
      LastName = 'testes existente',
      Company = 'testes existente',
      Email = 'testes.bot.morno@example.invalid',
      Status = 'Novo'
    );
    insert existente;

    Test.startTest();
    List<STE_BotRegistrarCandidato.Resultado> r = STE_BotRegistrarCandidato.registrar(
      new List<STE_BotRegistrarCandidato.Entrada>{
        entrada(
          existente.Email,
          'Sim',
          'Enviarei depois',
          'Não',
          'deve ser apagada'
        )
      }
    );
    Test.stopTest();

    Assert.isTrue(r[0].sucesso, r[0].mensagem);
    Assert.areEqual(String.valueOf(existente.Id), r[0].recordId);
    Assert.areEqual(
      1,
      [SELECT COUNT() FROM Lead WHERE Email = :existente.Email]
    );
    Lead l = [
      SELECT
        STE_Classificacao_Fila__c,
        STE_Prazo_Envio_CNH__c,
        STE_Ja_Trabalhou_Telecom__c,
        STE_Empresa_Telecom_Anterior__c,
        STE_MessagingSession_Id__c
      FROM Lead
      WHERE Id = :existente.Id
    ];
    Assert.areEqual('Morna', l.STE_Classificacao_Fila__c);
    Assert.isNotNull(l.STE_Prazo_Envio_CNH__c);
    Assert.areEqual('Não', l.STE_Ja_Trabalhou_Telecom__c);
    Assert.isNull(l.STE_Empresa_Telecom_Anterior__c);
    Assert.areEqual(
      String.valueOf((Id) SESSAO_TESTE),
      l.STE_MessagingSession_Id__c
    );
  }

  @IsTest
  static void atualizaContatoEmVezDeCriarLead() {
    Contact c = new Contact(
      LastName = 'testes contato',
      Email = 'testes.bot.contato@example.invalid'
    );
    insert c;

    Test.startTest();
    List<STE_BotRegistrarCandidato.Resultado> r = STE_BotRegistrarCandidato.registrar(
      new List<STE_BotRegistrarCandidato.Entrada>{
        entrada(c.Email, 'Sim', 'Vou enviar agora', 'Sim', 'testes Parceira B')
      }
    );
    Test.stopTest();

    Assert.isTrue(r[0].sucesso, r[0].mensagem);
    Assert.areEqual('Contact', r[0].tipoRegistro);
    Assert.areEqual(0, [SELECT COUNT() FROM Lead WHERE Email = :c.Email]);
    c = [
      SELECT
        STE_Faixa_Etaria__c,
        STE_Possui_CNH__c,
        STE_Ja_Trabalhou_Telecom__c,
        STE_Empresa_Telecom_Anterior__c,
        STE_MessagingSession_Id__c
      FROM Contact
      WHERE Id = :c.Id
    ];
    Assert.areEqual('De 20 a 50 anos', c.STE_Faixa_Etaria__c);
    Assert.areEqual('Sim, envio imediato', c.STE_Possui_CNH__c);
    Assert.areEqual('Sim', c.STE_Ja_Trabalhou_Telecom__c);
    Assert.areEqual('testes Parceira B', c.STE_Empresa_Telecom_Anterior__c);
    Assert.areEqual(
      String.valueOf((Id) SESSAO_TESTE),
      c.STE_MessagingSession_Id__c
    );
  }

  @IsTest
  static void criaLeadFrioQuandoIdadeNaoAtende() {
    Test.startTest();
    List<STE_BotRegistrarCandidato.Resultado> r = STE_BotRegistrarCandidato.registrar(
      new List<STE_BotRegistrarCandidato.Entrada>{
        entrada('testes.bot.frio@example.invalid', 'Não', null, 'Não', null)
      }
    );
    Test.stopTest();
    Lead l = [
      SELECT Status, STE_Classificacao_Fila__c, STE_Faixa_Etaria__c
      FROM Lead
      WHERE Id = :r[0].recordId
    ];
    Assert.areEqual('Desqualificado', l.Status);
    Assert.areEqual('Fria', l.STE_Classificacao_Fila__c);
    Assert.areEqual('Fora da faixa', l.STE_Faixa_Etaria__c);
  }

  @IsTest
  static void rejeitaEntradaSemEmail() {
    STE_BotRegistrarCandidato.Entrada e = entrada(
      null,
      'Sim',
      'Vou enviar agora',
      'Não',
      null
    );
    List<STE_BotRegistrarCandidato.Resultado> r = STE_BotRegistrarCandidato.registrar(
      new List<STE_BotRegistrarCandidato.Entrada>{ e }
    );
    Assert.isFalse(r[0].sucesso);
    Assert.isTrue(r[0].mensagem.contains('e-mail'));
    Assert.areEqual(0, STE_BotRegistrarCandidato.registrar(null).size());
  }

  @IsTest
  static void ignoraContextoDeMensageriaInvalidoSemPerderRegistro() {
    STE_BotRegistrarCandidato.Entrada e = entrada(
      'testes.bot.contexto.invalido@example.invalid',
      'Sim',
      'Vou enviar agora',
      'Não',
      null
    );
    e.routableId = 'sessao-invalida';
    e.endUserId = 'usuario-invalido';

    List<STE_BotRegistrarCandidato.Resultado> r = STE_BotRegistrarCandidato.registrar(
      new List<STE_BotRegistrarCandidato.Entrada>{ e }
    );

    Assert.isTrue(r[0].sucesso, r[0].mensagem);
    Assert.areEqual('Lead', r[0].tipoRegistro);
    Assert.areEqual(
      1,
      [SELECT COUNT() FROM Lead WHERE Email = :e.email],
      'Um contexto inválido não pode impedir o registro do candidato.'
    );
  }
}