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

  private static MessagingChannel canalTeste;

  /** Cria um MessagingEndUser real para verificar a gravação do vínculo. */
  private static MessagingEndUser novoEndUser(String telefone) {
    if (canalTeste == null) {
      MessagingChannel canal = new MessagingChannel(
        DeveloperName = 'STE_Canal_Teste_Vinculo',
        MasterLabel = 'STE Canal Teste Vínculo',
        MessageType = 'Text',
        MessagingPlatformKey = 'ste-canal-teste-vinculo'
      );
      // MessagingChannel é objeto de setup: isolar a DML evita MIXED_DML_OPERATION
      // quando o teste já mexeu em Lead antes de chegar aqui.
      System.runAs(new User(Id = UserInfo.getUserId())) {
        insert canal;
      }
      canalTeste = canal;
    }
    MessagingEndUser endUser = new MessagingEndUser(
      Name = 'testes end user ' + telefone,
      MessagingChannelId = canalTeste.Id,
      MessageType = 'Text',
      MessagingPlatformKey = telefone
    );
    insert endUser;
    return endUser;
  }

  private static MessagingEndUser vinculoDe(Id endUserId) {
    return [
      SELECT Id, LeadId, ContactId
      FROM MessagingEndUser
      WHERE Id = :endUserId
    ];
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
  static void semAnexoNaoMarcaCnhRecebida() {
    STE_BotRegistrarCandidato.Entrada e = entrada(
      'testes.bot.sem.anexo@example.invalid',
      'Sim',
      'Enviarei depois',
      'Não',
      null
    );

    Test.startTest();
    List<STE_BotRegistrarCandidato.Resultado> r = STE_BotRegistrarCandidato.registrar(
      new List<STE_BotRegistrarCandidato.Entrada>{ e }
    );
    Test.stopTest();

    Assert.isTrue(r[0].sucesso, r[0].mensagem);
    Lead l = [
      SELECT STE_CNH_Enviada__c, STE_Data_Envio_CNH__c, STE_Prazo_Envio_CNH__c
      FROM Lead
      WHERE Id = :r[0].recordId
    ];
    Assert.isFalse(
      l.STE_CNH_Enviada__c,
      'Sem arquivo na conversa a CNH não pode constar como recebida.'
    );
    Assert.isNull(l.STE_Data_Envio_CNH__c);
    Assert.isNotNull(
      l.STE_Prazo_Envio_CNH__c,
      'Quem ficou de enviar depois continua com prazo em aberto.'
    );
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
  static void desqualificaPorIdadeComMotivoEEtapaProprios() {
    Test.startTest();
    List<STE_BotRegistrarCandidato.Resultado> r = STE_BotRegistrarCandidato.registrar(
      new List<STE_BotRegistrarCandidato.Entrada>{
        entrada('testes.inelegivel.idade@example.invalid', 'Não', null, 'Não', null)
      }
    );
    Test.stopTest();

    Lead l = [
      SELECT Status, STE_Etapa_Bot__c, STE_Motivo_Desqualificacao__c
      FROM Lead
      WHERE Id = :r[0].recordId
    ];
    Assert.areEqual('Desqualificado', l.Status);
    Assert.areEqual(
      'Desqualificado',
      l.STE_Etapa_Bot__c,
      'Quem foi barrado não pode se confundir com quem concluiu a pré-inscrição.'
    );
    Assert.areEqual(
      'Fora da faixa etária',
      l.STE_Motivo_Desqualificacao__c
    );
  }

  @IsTest
  static void desqualificaPorGeneroVindoDoFormulario() {
    // O gênero chega pelo formulário do site, não pelo assistente.
    Lead existente = new Lead(
      LastName = 'testes inelegivel genero',
      Company = 'testes inelegivel genero',
      Email = 'testes.inelegivel.genero@example.invalid',
      STE_Genero__c = 'Feminino'
    );
    insert existente;

    Test.startTest();
    List<STE_BotRegistrarCandidato.Resultado> r = STE_BotRegistrarCandidato.registrar(
      new List<STE_BotRegistrarCandidato.Entrada>{
        entrada('testes.inelegivel.genero@example.invalid', 'Sim', 'Vou enviar agora', 'Não', null)
      }
    );
    Test.stopTest();

    Lead l = [
      SELECT Status, STE_Etapa_Bot__c, STE_Motivo_Desqualificacao__c
      FROM Lead
      WHERE Id = :existente.Id
    ];
    Assert.areEqual('Desqualificado', l.Status);
    Assert.areEqual(
      'Não atende ao perfil da turma',
      l.STE_Motivo_Desqualificacao__c
    );
  }

  @IsTest
  static void desqualificaQuemNaoTemCnh() {
    // "Não tenho CNH" só é declarado no formulário do site: o assistente
    // oferece apenas enviar agora ou depois.
    Lead existente = new Lead(
      LastName = 'testes inelegivel cnh',
      Company = 'testes inelegivel cnh',
      Email = 'testes.inelegivel.cnh@example.invalid',
      STE_Possui_CNH__c = 'Não'
    );
    insert existente;

    Test.startTest();
    STE_BotRegistrarCandidato.registrar(
      new List<STE_BotRegistrarCandidato.Entrada>{
        entrada('testes.inelegivel.cnh@example.invalid', 'Sim', null, 'Não', null)
      }
    );
    Test.stopTest();

    Lead l = [
      SELECT Status, STE_Possui_CNH__c, STE_Motivo_Desqualificacao__c
      FROM Lead
      WHERE Id = :existente.Id
    ];
    Assert.areEqual('Não', l.STE_Possui_CNH__c);
    Assert.areEqual('Desqualificado', l.Status);
    Assert.areEqual('Sem CNH', l.STE_Motivo_Desqualificacao__c);
  }

  @IsTest
  static void devolveElegibilidadeParaOAssistente() {
    // O bot usa este retorno para decidir entre encerrar e encaminhar.
    Test.startTest();
    List<STE_BotRegistrarCandidato.Resultado> barrado = STE_BotRegistrarCandidato.registrar(
      new List<STE_BotRegistrarCandidato.Entrada>{
        entrada('testes.retorno.barrado@example.invalid', 'Não', null, 'Não', null)
      }
    );
    List<STE_BotRegistrarCandidato.Resultado> aprovado = STE_BotRegistrarCandidato.registrar(
      new List<STE_BotRegistrarCandidato.Entrada>{
        entrada('testes.retorno.ok@example.invalid', 'Sim', 'Vou enviar agora', 'Não', null)
      }
    );
    Test.stopTest();

    Assert.isFalse(
      barrado[0].elegivel,
      'Quem foi barrado por um critério não pode voltar como elegível.'
    );
    Assert.isTrue(
      aprovado[0].elegivel,
      'Quem atende aos critérios segue para atendimento.'
    );
  }

  @IsTest
  static void candidatoElegivelNaoRecebeMotivo() {
    Test.startTest();
    List<STE_BotRegistrarCandidato.Resultado> r = STE_BotRegistrarCandidato.registrar(
      new List<STE_BotRegistrarCandidato.Entrada>{
        entrada('testes.elegivel@example.invalid', 'Sim', 'Vou enviar agora', 'Não', null)
      }
    );
    Test.stopTest();

    Lead l = [
      SELECT Status, STE_Etapa_Bot__c, STE_Motivo_Desqualificacao__c
      FROM Lead
      WHERE Id = :r[0].recordId
    ];
    Assert.areEqual('Validação', l.Status);
    Assert.areEqual('Concluído', l.STE_Etapa_Bot__c);
    Assert.isNull(
      l.STE_Motivo_Desqualificacao__c,
      'Quem atende aos critérios não pode ficar com motivo de recusa.'
    );
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

  @IsTest
  static void vinculaLeadNovoAoEndUser() {
    MessagingEndUser endUser = novoEndUser('5511900000001');
    STE_BotRegistrarCandidato.Entrada e = entrada(
      'testes.bot.vinculo.lead@example.invalid',
      'Sim',
      'Vou enviar agora',
      'Não',
      null
    );
    e.endUserId = String.valueOf(endUser.Id);

    Test.startTest();
    List<STE_BotRegistrarCandidato.Resultado> r = STE_BotRegistrarCandidato.registrar(
      new List<STE_BotRegistrarCandidato.Entrada>{ e }
    );
    Test.stopTest();

    Assert.isTrue(r[0].sucesso, r[0].mensagem);
    Assert.areEqual('Lead', r[0].tipoRegistro);
    MessagingEndUser vinculo = vinculoDe(endUser.Id);
    Assert.areEqual(
      r[0].recordId,
      String.valueOf(vinculo.LeadId),
      'O telefone precisa ficar ligado ao Lead que o bot acabou de registrar.'
    );
    Assert.isNull(vinculo.ContactId);
  }

  @IsTest
  static void vinculaContatoELimpaLead() {
    Contact c = new Contact(
      LastName = 'testes contato vinculo',
      Email = 'testes.bot.vinculo.contato@example.invalid'
    );
    insert c;
    Lead antigo = new Lead(
      LastName = 'testes lead antigo',
      Company = 'testes lead antigo',
      Email = 'testes.bot.vinculo.antigo@example.invalid',
      Status = 'Novo'
    );
    insert antigo;

    MessagingEndUser endUser = novoEndUser('5511900000002');
    update new MessagingEndUser(Id = endUser.Id, LeadId = antigo.Id);

    STE_BotRegistrarCandidato.Entrada e = entrada(
      c.Email,
      'Sim',
      'Vou enviar agora',
      'Não',
      null
    );
    e.endUserId = String.valueOf(endUser.Id);

    Test.startTest();
    List<STE_BotRegistrarCandidato.Resultado> r = STE_BotRegistrarCandidato.registrar(
      new List<STE_BotRegistrarCandidato.Entrada>{ e }
    );
    Test.stopTest();

    Assert.isTrue(r[0].sucesso, r[0].mensagem);
    Assert.areEqual('Contact', r[0].tipoRegistro);
    MessagingEndUser vinculo = vinculoDe(endUser.Id);
    Assert.areEqual(c.Id, vinculo.ContactId);
    Assert.isNull(
      vinculo.LeadId,
      'Contato tem precedência: o LeadId antigo deve ser limpo.'
    );
  }

  @IsTest
  static void naoSobrescreveContatoComLead() {
    Contact c = new Contact(
      LastName = 'testes contato fixo',
      Email = 'testes.bot.contato.fixo@example.invalid'
    );
    insert c;
    MessagingEndUser endUser = novoEndUser('5511900000003');
    update new MessagingEndUser(Id = endUser.Id, ContactId = c.Id);

    // O e-mail informado casa com um Lead, então o e-mail vence e a ação
    // devolve Lead. Mesmo assim o telefone não pode deixar de apontar para o
    // Contato, que é o registro mais avançado da pessoa.
    Lead outro = new Lead(
      LastName = 'testes lead de outro email',
      Company = 'testes lead de outro email',
      Email = 'testes.bot.lead.sem.roubo@example.invalid',
      Status = 'Novo'
    );
    insert outro;

    STE_BotRegistrarCandidato.Entrada e = entrada(
      outro.Email,
      'Sim',
      'Vou enviar agora',
      'Não',
      null
    );
    e.endUserId = String.valueOf(endUser.Id);

    Test.startTest();
    List<STE_BotRegistrarCandidato.Resultado> r = STE_BotRegistrarCandidato.registrar(
      new List<STE_BotRegistrarCandidato.Entrada>{ e }
    );
    Test.stopTest();

    Assert.isTrue(r[0].sucesso, r[0].mensagem);
    Assert.areEqual('Lead', r[0].tipoRegistro);
    Assert.areEqual(String.valueOf(outro.Id), r[0].recordId);
    MessagingEndUser vinculo = vinculoDe(endUser.Id);
    Assert.areEqual(c.Id, vinculo.ContactId);
    Assert.isNull(
      vinculo.LeadId,
      'Um telefone já ligado a Contato não pode ser repontado para Lead.'
    );
  }

  @IsTest
  static void sobrescreveVinculoComLeadMaisRecente() {
    Lead antigo = new Lead(
      LastName = 'testes lead anterior',
      Company = 'testes lead anterior',
      Email = 'testes.bot.lead.anterior@example.invalid',
      Status = 'Novo'
    );
    insert antigo;
    MessagingEndUser endUser = novoEndUser('5511900000004');
    update new MessagingEndUser(Id = endUser.Id, LeadId = antigo.Id);

    // O e-mail informado casa com outro Lead aberto. O e-mail vence a Regra 4,
    // e o vínculo do telefone precisa acompanhar o registro que passou a ser
    // usado, senão a próxima conversa volta para o Lead errado.
    Lead recente = new Lead(
      LastName = 'testes lead recente',
      Company = 'testes lead recente',
      Email = 'testes.bot.lead.recente@example.invalid',
      Status = 'Novo'
    );
    insert recente;

    STE_BotRegistrarCandidato.Entrada e = entrada(
      recente.Email,
      'Sim',
      'Vou enviar agora',
      'Não',
      null
    );
    e.endUserId = String.valueOf(endUser.Id);

    Test.startTest();
    List<STE_BotRegistrarCandidato.Resultado> r = STE_BotRegistrarCandidato.registrar(
      new List<STE_BotRegistrarCandidato.Entrada>{ e }
    );
    Test.stopTest();

    Assert.isTrue(r[0].sucesso, r[0].mensagem);
    MessagingEndUser vinculo = vinculoDe(endUser.Id);
    Assert.areEqual(r[0].recordId, String.valueOf(vinculo.LeadId));
    Assert.areNotEqual(
      antigo.Id,
      vinculo.LeadId,
      'O vínculo deve passar a apontar para o Lead da conversa mais recente.'
    );
  }

  @IsTest
  static void reaproveitaLeadPeloVinculoQuandoOEmailMuda() {
    MessagingEndUser endUser = novoEndUser('5511977776666');
    Lead anterior = new Lead(
      LastName = 'testes regra4 vinculo',
      Company = 'testes regra4 vinculo',
      Email = 'testes.regra4.email.antigo@example.invalid',
      Status = 'Novo'
    );
    insert anterior;
    update new MessagingEndUser(Id = endUser.Id, LeadId = anterior.Id);

    STE_BotRegistrarCandidato.Entrada e = entrada(
      'testes.regra4.email.novo@example.invalid',
      'Sim',
      'Enviarei depois',
      'Não',
      null
    );
    e.endUserId = String.valueOf(endUser.Id);

    Test.startTest();
    List<STE_BotRegistrarCandidato.Resultado> r = STE_BotRegistrarCandidato.registrar(
      new List<STE_BotRegistrarCandidato.Entrada>{ e }
    );
    Test.stopTest();

    Assert.isTrue(r[0].sucesso, r[0].mensagem);
    Assert.areEqual(
      String.valueOf(anterior.Id),
      r[0].recordId,
      'E-mail diferente não pode gerar Lead novo quando o telefone já conhece a pessoa.'
    );
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Lead WHERE Email = :e.email],
      'Nenhum Lead deve ser criado com o e-mail novo.'
    );
    Lead l = [
      SELECT Email, STE_Classificacao_Fila__c
      FROM Lead
      WHERE Id = :anterior.Id
    ];
    Assert.areEqual(
      'testes.regra4.email.antigo@example.invalid',
      l.Email,
      'O e-mail original do cadastro é preservado.'
    );
    Assert.areEqual('Morna', l.STE_Classificacao_Fila__c);
  }

  @IsTest
  static void reaproveitaLeadPeloTelefoneSemVinculo() {
    MessagingEndUser endUser = novoEndUser('5511955554444');
    Lead anterior = new Lead(
      LastName = 'testes regra4 telefone',
      Company = 'testes regra4 telefone',
      Email = 'testes.regra4.telefone.antigo@example.invalid',
      Status = 'Novo',
      STE_Telefone_E164__c = '5511955554444'
    );
    insert anterior;

    STE_BotRegistrarCandidato.Entrada e = entrada(
      'testes.regra4.telefone.novo@example.invalid',
      'Sim',
      'Vou enviar agora',
      'Não',
      null
    );
    e.endUserId = String.valueOf(endUser.Id);

    Test.startTest();
    List<STE_BotRegistrarCandidato.Resultado> r = STE_BotRegistrarCandidato.registrar(
      new List<STE_BotRegistrarCandidato.Entrada>{ e }
    );
    Test.stopTest();

    Assert.areEqual(String.valueOf(anterior.Id), r[0].recordId);
    Assert.areEqual(
      anterior.Id,
      vinculoDe(endUser.Id).LeadId,
      'Ao reaproveitar pelo telefone, o vínculo passa a existir.'
    );
  }

  @IsTest
  static void reaproveitaLeadDeOitoDigitosVindoDeOutraOrigem() {
    MessagingEndUser endUser = novoEndUser('5511987654321');
    Lead webToLead = new Lead(
      LastName = 'testes regra4 web',
      Company = 'testes regra4 web',
      Email = 'testes.regra4.web@example.invalid',
      Status = 'Novo',
      LeadSource = 'Web',
      STE_Telefone_E164__c = '551187654321'
    );
    insert webToLead;

    STE_BotRegistrarCandidato.Entrada e = entrada(
      'testes.regra4.web.outro@example.invalid',
      'Sim',
      'Enviarei depois',
      'Não',
      null
    );
    e.endUserId = String.valueOf(endUser.Id);

    Test.startTest();
    List<STE_BotRegistrarCandidato.Resultado> r = STE_BotRegistrarCandidato.registrar(
      new List<STE_BotRegistrarCandidato.Entrada>{ e }
    );
    Test.stopTest();

    Assert.areEqual(
      String.valueOf(webToLead.Id),
      r[0].recordId,
      'Registro de outra origem com 8 dígitos deve ser reaproveitado.'
    );
  }

  @IsTest
  static void emailTemPrecedenciaSobreOTelefone() {
    MessagingEndUser endUser = novoEndUser('5511933332222');
    Lead doTelefone = new Lead(
      LastName = 'testes regra4 do telefone',
      Company = 'testes regra4 do telefone',
      Email = 'testes.regra4.dotelefone@example.invalid',
      Status = 'Novo',
      STE_Telefone_E164__c = '5511933332222'
    );
    insert doTelefone;
    Lead doEmail = new Lead(
      LastName = 'testes regra4 do email',
      Company = 'testes regra4 do email',
      Email = 'testes.regra4.doemail@example.invalid',
      Status = 'Novo'
    );
    insert doEmail;

    STE_BotRegistrarCandidato.Entrada e = entrada(
      doEmail.Email,
      'Sim',
      'Enviarei depois',
      'Não',
      null
    );
    e.endUserId = String.valueOf(endUser.Id);

    Test.startTest();
    List<STE_BotRegistrarCandidato.Resultado> r = STE_BotRegistrarCandidato.registrar(
      new List<STE_BotRegistrarCandidato.Entrada>{ e }
    );
    Test.stopTest();

    Assert.areEqual(
      String.valueOf(doEmail.Id),
      r[0].recordId,
      'Quando o e-mail informado casa, ele vence o telefone.'
    );
  }

  @IsTest
  static void contatoDoVinculoVenceOLeadDoTelefone() {
    MessagingEndUser endUser = novoEndUser('5511922221111');
    Contact contato = new Contact(
      LastName = 'testes regra4 contato',
      Email = 'testes.regra4.contato@example.invalid'
    );
    insert contato;
    update new MessagingEndUser(Id = endUser.Id, ContactId = contato.Id);
    Lead lead = new Lead(
      LastName = 'testes regra4 lead solto',
      Company = 'testes regra4 lead solto',
      Email = 'testes.regra4.leadsolto@example.invalid',
      Status = 'Novo',
      STE_Telefone_E164__c = '5511922221111'
    );
    insert lead;

    STE_BotRegistrarCandidato.Entrada e = entrada(
      'testes.regra4.terceiro@example.invalid',
      'Sim',
      'Enviarei depois',
      'Não',
      null
    );
    e.endUserId = String.valueOf(endUser.Id);

    Test.startTest();
    List<STE_BotRegistrarCandidato.Resultado> r = STE_BotRegistrarCandidato.registrar(
      new List<STE_BotRegistrarCandidato.Entrada>{ e }
    );
    Test.stopTest();

    Assert.areEqual('Contact', r[0].tipoRegistro);
    Assert.areEqual(String.valueOf(contato.Id), r[0].recordId);
  }

  @IsTest
  static void criaLeadQuandoOTelefoneNaoConheceNinguem() {
    MessagingEndUser endUser = novoEndUser('5511911110000');
    STE_BotRegistrarCandidato.Entrada e = entrada(
      'testes.regra4.novato@example.invalid',
      'Sim',
      'Enviarei depois',
      'Não',
      null
    );
    e.endUserId = String.valueOf(endUser.Id);

    Test.startTest();
    List<STE_BotRegistrarCandidato.Resultado> r = STE_BotRegistrarCandidato.registrar(
      new List<STE_BotRegistrarCandidato.Entrada>{ e }
    );
    Test.stopTest();

    Assert.isTrue(r[0].sucesso, r[0].mensagem);
    Assert.areEqual('Lead', r[0].tipoRegistro);
    Assert.areEqual(1, [SELECT COUNT() FROM Lead WHERE Email = :e.email]);
  }

  @IsTest
  static void gravaTelefoneDoEndUserNoLead() {
    MessagingEndUser endUser = novoEndUser('5511988887777');
    STE_BotRegistrarCandidato.Entrada e = entrada(
      'testes.bot.telefone@example.invalid',
      'Sim',
      'Vou enviar agora',
      'Não',
      null
    );
    e.endUserId = String.valueOf(endUser.Id);

    Test.startTest();
    List<STE_BotRegistrarCandidato.Resultado> r = STE_BotRegistrarCandidato.registrar(
      new List<STE_BotRegistrarCandidato.Entrada>{ e }
    );
    Test.stopTest();

    Assert.isTrue(r[0].sucesso, r[0].mensagem);
    Lead l = [
      SELECT MobilePhone, STE_Telefone_E164__c
      FROM Lead
      WHERE Id = :r[0].recordId
    ];
    Assert.areEqual(
      '5511988887777',
      l.STE_Telefone_E164__c,
      'O telefone técnico deve ficar só com dígitos, para casar por igualdade.'
    );
    Assert.areEqual('+5511988887777', l.MobilePhone);
  }

  @IsTest
  static void naoSobrescreveMobilePhoneJaPreenchido() {
    Lead existente = new Lead(
      LastName = 'testes telefone existente',
      Company = 'testes telefone existente',
      Email = 'testes.bot.telefone.existente@example.invalid',
      Status = 'Novo',
      MobilePhone = '(11) 3333-4444'
    );
    insert existente;

    MessagingEndUser endUser = novoEndUser('5511988886666');
    STE_BotRegistrarCandidato.Entrada e = entrada(
      existente.Email,
      'Sim',
      'Enviarei depois',
      'Não',
      null
    );
    e.endUserId = String.valueOf(endUser.Id);

    Test.startTest();
    STE_BotRegistrarCandidato.registrar(
      new List<STE_BotRegistrarCandidato.Entrada>{ e }
    );
    Test.stopTest();

    Lead l = [
      SELECT MobilePhone, STE_Telefone_E164__c
      FROM Lead
      WHERE Id = :existente.Id
    ];
    Assert.areEqual(
      '(11) 3333-4444',
      l.MobilePhone,
      'Telefone já informado pelo candidato não deve ser sobrescrito.'
    );
    Assert.areEqual('5511988886666', l.STE_Telefone_E164__c);
  }

  @IsTest
  static void naoFalhaQuandoEndUserNaoExiste() {
    STE_BotRegistrarCandidato.Entrada e = entrada(
      'testes.bot.enduser.inexistente@example.invalid',
      'Sim',
      'Vou enviar agora',
      'Não',
      null
    );
    e.endUserId = '0PA000000000001';

    Test.startTest();
    List<STE_BotRegistrarCandidato.Resultado> r = STE_BotRegistrarCandidato.registrar(
      new List<STE_BotRegistrarCandidato.Entrada>{ e }
    );
    Test.stopTest();

    Assert.isTrue(r[0].sucesso, r[0].mensagem);
    Assert.areEqual(
      1,
      [SELECT COUNT() FROM Lead WHERE Email = :e.email],
      'Um end user inexistente não pode impedir o registro do candidato.'
    );
  }
}