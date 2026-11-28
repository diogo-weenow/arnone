/**
 * CLICKUP-11812 — Funil de status do Lead da S Company (Captacao_SCO).
 * Cobre o Flow SCO_Definir_BDR_Responsavel e as VRs SCO_Reuniao_Agendada_Exige_Dados
 * e SCO_Reuniao_Realizada_Nao_Futura, além do isolamento das outras unidades.
 * CLICKUP-12117 — "Reunião agendada" exige só a data; o Executivo responsável já
 * preenchido só é trocado ou apagado pelo papel Diretoria_SCO (VR SCO_Executivo_Troca_So_Diretoria).
 * Os cenários T1..T10 rodam com personas reais (Standard User + PS_SCO_Comercial + papel).
 */
@IsTest
private class SCOFunilLeadTest {
  private static final String MSG_REUNIAO = 'Informe a data da reunião agendada.';
  private static final String MSG_EXECUTIVO = 'Só a Diretora Comercial pode trocar o Executivo responsável.';
  private static final String MSG_FUTURA = 'A data da reunião realizada não pode ser futura.';

  private static Id rt(String devName) {
    return Schema.SObjectType.Lead.getRecordTypeInfosByDeveloperName()
      .get(devName)
      .getRecordTypeId();
  }

  private static List<User> usuarios(Integer qtd) {
    List<User> us = new List<User>();
    for (Integer i = 0; i < qtd; i++) {
      String unico = String.valueOf(Math.abs(Crypto.getRandomInteger())) + i;
      us.add(
        new User(
          FirstName = 'SCO',
          LastName = 'Funil ' + i,
          Alias = ('scof' + i).left(8),
          Email = 'sco.funil' + i + '@arnone.invalid',
          Username = 'sco.funil.' + unico + '@arnone.funil.test.invalid',
          ProfileId = UserInfo.getProfileId(),
          TimeZoneSidKey = 'America/Sao_Paulo',
          LocaleSidKey = 'pt_BR',
          EmailEncodingKey = 'UTF-8',
          LanguageLocaleKey = 'pt_BR'
        )
      );
    }
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert us;
    }
    return us;
  }

  private static Lead leadSco(Id ownerId) {
    Lead l = new Lead(
      RecordTypeId = rt('SCO'),
      LastName = 'Lead Funil SCO',
      Company = 'Empresa Funil SCO',
      LeadSource = 'Indicacao',
      Status = 'Novo',
      OwnerId = ownerId
    );
    insert l;
    return l;
  }

  private static Lead recarregar(Id leadId) {
    return [
      SELECT Id, Status, OwnerId, SCO_BDR_Responsavel__c, SCO_Data_Reuniao_Realizada__c
      FROM Lead
      WHERE Id = :leadId
    ];
  }

  private static String erroAoAtualizar(Lead l) {
    try {
      update l;
    } catch (DmlException e) {
      return e.getMessage();
    }
    return null;
  }

  // 1. Caminho feliz: entrar em "Em contato" grava o dono como BDR responsável.
  @IsTest
  static void emContatoPreencheBdrComDono() {
    User dono = usuarios(1)[0];
    Lead l = leadSco(dono.Id);
    System.assertEquals(null, recarregar(l.Id).SCO_BDR_Responsavel__c, 'Em Novo o BDR fica vazio.');

    Test.startTest();
    update new Lead(Id = l.Id, Status = 'Em contato');
    Test.stopTest();

    System.assertEquals(dono.Id, recarregar(l.Id).SCO_BDR_Responsavel__c);
  }

  // 2. BDR informado manualmente não é sobrescrito, nem com troca de dono nem avançando etapa.
  @IsTest
  static void bdrManualNaoESobrescrito() {
    List<User> us = usuarios(3);
    Lead l = leadSco(us[0].Id);
    update new Lead(Id = l.Id, Status = 'Em contato');
    System.assertEquals(us[0].Id, recarregar(l.Id).SCO_BDR_Responsavel__c);

    Test.startTest();
    update new Lead(Id = l.Id, SCO_BDR_Responsavel__c = us[1].Id);
    update new Lead(Id = l.Id, OwnerId = us[2].Id);
    // CLICKUP-11813: "Em nutrição" exige motivo e data de retomada futura.
    update new Lead(
      Id = l.Id,
      Status = 'Em nutrição',
      SCO_Motivo_Nutricao__c = 'Sem retorno',
      SCO_Data_Retomada__c = Date.today().addDays(30)
    );
    update new Lead(Id = l.Id, Status = 'Em contato');
    Test.stopTest();

    Lead depois = recarregar(l.Id);
    System.assertEquals(us[2].Id, depois.OwnerId);
    System.assertEquals(us[1].Id, depois.SCO_BDR_Responsavel__c, 'O valor manual deve permanecer.');
  }

  // 2b. Lead ainda em fila: "Em contato" não grava BDR (lookup só aceita usuário).
  @IsTest
  static void leadEmFilaFicaSemBdr() {
    Group fila;
    System.runAs(new User(Id = UserInfo.getUserId())) {
      fila = new Group(Name = 'Fila Funil SCO Teste', DeveloperName = 'Fila_Funil_SCO_Teste', Type = 'Queue');
      insert fila;
      insert new QueueSobject(QueueId = fila.Id, SobjectType = 'Lead');
    }
    Lead l = leadSco(fila.Id);

    Test.startTest();
    update new Lead(Id = l.Id, Status = 'Em contato');
    Test.stopTest();

    System.assertEquals(null, recarregar(l.Id).SCO_BDR_Responsavel__c);
  }

  // 3. "Reunião agendada" exige só a data da reunião (CLICKUP-12117: o Executivo não é exigido).
  @IsTest
  static void reuniaoAgendadaExigeDados() {
    User u = usuarios(1)[0];
    Lead l = leadSco(u.Id);

    Test.startTest();
    String semNada = erroAoAtualizar(new Lead(Id = l.Id, Status = 'Reunião agendada'));
    String semData = erroAoAtualizar(
      new Lead(Id = l.Id, Status = 'Reunião agendada', SCO_Executivo_Responsavel__c = u.Id)
    );
    String soData = erroAoAtualizar(
      new Lead(Id = l.Id, Status = 'Reunião agendada', SCO_Data_Reuniao_Agendada__c = System.now().addDays(2))
    );
    Test.stopTest();

    System.assert(semNada != null && semNada.contains(MSG_REUNIAO), semNada);
    System.assert(semData != null && semData.contains(MSG_REUNIAO), semData);
    System.assertEquals(null, soData, 'Só com a data o save passa, sem Executivo.');
    Lead depois = [SELECT Status, SCO_Executivo_Responsavel__c FROM Lead WHERE Id = :l.Id];
    System.assertEquals('Reunião agendada', depois.Status);
    System.assertEquals(null, depois.SCO_Executivo_Responsavel__c);
  }

  // 4. Data da reunião realizada não aceita data futura; hoje é aceita.
  @IsTest
  static void reuniaoRealizadaNaoFutura() {
    Lead l = leadSco(UserInfo.getUserId());

    Test.startTest();
    String futura = erroAoAtualizar(new Lead(Id = l.Id, SCO_Data_Reuniao_Realizada__c = Date.today().addDays(1)));
    String hoje = erroAoAtualizar(new Lead(Id = l.Id, SCO_Data_Reuniao_Realizada__c = Date.today()));
    Test.stopTest();

    System.assert(futura != null && futura.contains(MSG_FUTURA), futura);
    System.assertEquals(null, hoje);
  }

  // H6: desqualificar não limpa a data da reunião realizada.
  @IsTest
  static void desqualificarMantemDataRealizada() {
    User u = usuarios(1)[0];
    Lead l = leadSco(u.Id);
    update new Lead(
      Id = l.Id,
      Status = 'Reunião agendada',
      SCO_Executivo_Responsavel__c = u.Id,
      SCO_Data_Reuniao_Agendada__c = System.now().addDays(-1),
      SCO_Data_Reuniao_Realizada__c = Date.today()
    );

    Test.startTest();
    // CLICKUP-11813: desqualificar exige motivo e, com reunião realizada, o motivo da reunião sem avanço.
    update new Lead(
      Id = l.Id,
      Status = 'Desqualificado',
      SCO_Motivo_Desqualificacao__c = 'Fora do perfil',
      SCO_Motivo_Reuniao_Sem_Avanco__c = 'Sem fit após a reunião.'
    );
    Test.stopTest();

    Lead depois = recarregar(l.Id);
    System.assertEquals('Desqualificado', depois.Status);
    System.assertEquals(Date.today(), depois.SCO_Data_Reuniao_Realizada__c);
  }

  // 5. Isolamento: ADV e ESG seguem no Captacao_Padrao; VRs e flow SCO não disparam.
  @IsTest
  static void outrasUnidadesNaoSaoAfetadas() {
    User u = usuarios(1)[0];
    List<Lead> leads = new List<Lead>();
    for (String bu : new List<String>{ 'ADV', 'ESG' }) {
      leads.add(
        new Lead(RecordTypeId = rt(bu), LastName = 'Lead ' + bu, Company = 'Empresa ' + bu, Status = 'Novo', OwnerId = u.Id)
      );
    }
    insert leads;

    Test.startTest();
    for (String st : new List<String>{ 'Em Qualificação', 'Nutrição', 'Qualificado', 'Desqualificado' }) {
      for (Lead l : leads) {
        l.Status = st;
        // Data futura e Status de reunião sem dados: as VRs SCO não podem disparar fora do RT SCO.
        l.SCO_Data_Reuniao_Realizada__c = Date.today().addDays(5);
      }
      update leads;
    }
    Test.stopTest();

    for (Lead l : [SELECT Status, SCO_BDR_Responsavel__c FROM Lead WHERE Id IN :leads]) {
      System.assertEquals('Desqualificado', l.Status);
      System.assertEquals(null, l.SCO_BDR_Responsavel__c);
    }
  }

  // 6. Conversão: SCO salva e converte em "Convertido"; ADV segue convertendo em "Qualificado".
  @IsTest
  static void conversaoScoEOutrasUnidades() {
    Lead sco = leadSco(UserInfo.getUserId());
    Lead adv = new Lead(RecordTypeId = rt('ADV'), LastName = 'Lead ADV Conv', Company = 'Empresa ADV Conv', Status = 'Novo');
    insert adv;

    Test.startTest();
    System.assertEquals(null, erroAoAtualizar(new Lead(Id = sco.Id, Status = 'Convertido')));

    Database.LeadConvert lcSco = new Database.LeadConvert();
    lcSco.setLeadId(sco.Id);
    lcSco.setConvertedStatus('Convertido');
    lcSco.setDoNotCreateOpportunity(true);

    Database.LeadConvert lcAdv = new Database.LeadConvert();
    lcAdv.setLeadId(adv.Id);
    lcAdv.setConvertedStatus('Qualificado');
    lcAdv.setDoNotCreateOpportunity(true);

    List<Database.LeadConvertResult> rs = Database.convertLead(new List<Database.LeadConvert>{ lcSco, lcAdv });
    Test.stopTest();

    for (Database.LeadConvertResult r : rs) {
      System.assert(r.isSuccess(), String.valueOf(r.getErrors()));
    }
    Map<Id, Lead> conv = new Map<Id, Lead>([SELECT Status, IsConverted FROM Lead WHERE Id IN (:sco.Id, :adv.Id)]);
    System.assertEquals('Convertido', conv.get(sco.Id).Status);
    System.assert(conv.get(sco.Id).IsConverted);
    System.assertEquals('Qualificado', conv.get(adv.Id).Status);
    System.assert(conv.get(adv.Id).IsConverted);
  }

  // ---------------------------------------------------------------------------
  // CLICKUP-12117 — cenários por persona (T1..T10).
  // ---------------------------------------------------------------------------

  /** Standard User + PS_SCO_Comercial no papel informado. Inserido como setup para evitar MIXED_DML. */
  private static User persona(String papelDevName, String sufixo) {
    Id perfilId = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1].Id;
    Id papelId = [SELECT Id FROM UserRole WHERE DeveloperName = :papelDevName LIMIT 1].Id;
    Id psId = [SELECT Id FROM PermissionSet WHERE Name = 'PS_SCO_Comercial' LIMIT 1].Id;
    String unico = String.valueOf(Math.abs(Crypto.getRandomInteger()));
    User u = new User(
      FirstName = 'SCO',
      LastName = 'Persona ' + sufixo,
      Alias = ('sp' + sufixo).left(8),
      Email = 'sco.persona.' + sufixo + '@arnone.invalid',
      Username = 'sco.persona.' + sufixo + '.' + unico + '@arnone.funil.test.invalid',
      ProfileId = perfilId,
      UserRoleId = papelId,
      TimeZoneSidKey = 'America/Sao_Paulo',
      LocaleSidKey = 'pt_BR',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'pt_BR'
    );
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert u;
      insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = psId);
    }
    return u;
  }

  private static User bdr() {
    return persona('Comercial_SCO', 'bdr');
  }

  private static User diretora() {
    return persona('Diretoria_SCO', 'dir');
  }

  /** Lead SCO criado pelo próprio BDR (dono), com nome único para não acionar regras de duplicidade. */
  private static Lead leadScoDoBdr(User b, String marca) {
    Lead l = new Lead(
      RecordTypeId = rt('SCO'),
      LastName = 'Lead 12117 ' + marca,
      Company = 'Empresa 12117 ' + marca,
      LeadSource = 'Indicacao',
      Status = 'Novo'
    );
    System.runAs(b) {
      insert l;
    }
    return l;
  }

  private static Boolean contem(String erro, String msg) {
    return erro != null && erro.contains(msg);
  }

  private static Id executivoAtual(Id leadId) {
    return [SELECT SCO_Executivo_Responsavel__c FROM Lead WHERE Id = :leadId].SCO_Executivo_Responsavel__c;
  }

  // T1. BDR: "Reunião agendada" sem data é recusado com a mensagem nova.
  @IsTest
  static void t1BdrReuniaoSemDataRecusa() {
    User b = bdr();
    Lead l = leadScoDoBdr(b, 'T1');
    String erro;
    Test.startTest();
    System.runAs(b) {
      erro = erroAoAtualizar(new Lead(Id = l.Id, Status = 'Reunião agendada'));
    }
    Test.stopTest();
    Assert.isTrue(contem(erro, MSG_REUNIAO), 'Sem data deve recusar com a mensagem nova. Obtido: ' + erro);
    Assert.areEqual('Novo', recarregar(l.Id).Status, 'O Status não pode mudar quando a VR recusa.');
  }

  // T2. BDR: com data e sem Executivo, salva.
  @IsTest
  static void t2BdrReuniaoComDataSemExecutivoSalva() {
    User b = bdr();
    Lead l = leadScoDoBdr(b, 'T2');
    String erro;
    Test.startTest();
    System.runAs(b) {
      erro = erroAoAtualizar(
        new Lead(Id = l.Id, Status = 'Reunião agendada', SCO_Data_Reuniao_Agendada__c = System.now().addDays(3))
      );
    }
    Test.stopTest();
    Assert.isNull(erro, 'Com a data, o save deve passar sem Executivo. Obtido: ' + erro);
    Assert.areEqual('Reunião agendada', recarregar(l.Id).Status, 'Status deve ficar em Reunião agendada.');
    Assert.isNull(executivoAtual(l.Id), 'Este card não preenche o Executivo (é do CLICKUP-12161).');
  }

  // T3. BDR: Executivo vazio recebe valor (primeiro preenchimento é livre).
  @IsTest
  static void t3BdrPrimeiroPreenchimentoDoExecutivoSalva() {
    User b = bdr();
    User exec = usuarios(1)[0];
    Lead l = leadScoDoBdr(b, 'T3');
    String erro;
    Test.startTest();
    System.runAs(b) {
      erro = erroAoAtualizar(new Lead(Id = l.Id, SCO_Executivo_Responsavel__c = exec.Id));
    }
    Test.stopTest();
    Assert.isNull(erro, 'Primeiro preenchimento do Executivo deve ser livre. Obtido: ' + erro);
    Assert.areEqual(exec.Id, executivoAtual(l.Id), 'O Executivo deve ficar gravado.');
  }

  // T4. BDR: trocar um Executivo já preenchido é recusado.
  @IsTest
  static void t4BdrTrocaExecutivoRecusa() {
    User b = bdr();
    List<User> execs = usuarios(2);
    Lead l = leadScoDoBdr(b, 'T4');
    String erro;
    Test.startTest();
    System.runAs(b) {
      update new Lead(Id = l.Id, SCO_Executivo_Responsavel__c = execs[0].Id);
      erro = erroAoAtualizar(new Lead(Id = l.Id, SCO_Executivo_Responsavel__c = execs[1].Id));
    }
    Test.stopTest();
    Assert.isTrue(contem(erro, MSG_EXECUTIVO), 'Troca pelo BDR deve recusar. Obtido: ' + erro);
    Assert.areEqual(execs[0].Id, executivoAtual(l.Id), 'O Executivo original deve permanecer.');
  }

  // T5. BDR: apagar um Executivo já preenchido é recusado.
  @IsTest
  static void t5BdrApagaExecutivoRecusa() {
    User b = bdr();
    User exec = usuarios(1)[0];
    Lead l = leadScoDoBdr(b, 'T5');
    String erro;
    Test.startTest();
    System.runAs(b) {
      update new Lead(Id = l.Id, SCO_Executivo_Responsavel__c = exec.Id);
      erro = erroAoAtualizar(new Lead(Id = l.Id, SCO_Executivo_Responsavel__c = null));
    }
    Test.stopTest();
    Assert.isTrue(contem(erro, MSG_EXECUTIVO), 'Apagar pelo BDR deve recusar. Obtido: ' + erro);
    Assert.areEqual(exec.Id, executivoAtual(l.Id), 'O Executivo original deve permanecer.');
  }

  // T5b. Usuário sem papel (administrador; $UserRole vazio) também não troca o Executivo de Lead SCO.
  // Substitui a E2E pela CLI, que não pôde rodar porque o perfil do admin não tem o RT SCO.
  @IsTest
  static void t5bUsuarioSemPapelTrocaExecutivoRecusa() {
    User semPapel = usuarios(1)[0]; // mesmo perfil do executor (administrador), sem UserRoleId
    Assert.isNull([SELECT UserRoleId FROM User WHERE Id = :semPapel.Id].UserRoleId, 'Pré-condição: usuário sem papel.');
    List<User> execs = usuarios(2);
    Lead l = leadSco(semPapel.Id);
    update new Lead(Id = l.Id, SCO_Executivo_Responsavel__c = execs[0].Id);
    String erro;
    Test.startTest();
    System.runAs(semPapel) {
      erro = erroAoAtualizar(new Lead(Id = l.Id, SCO_Executivo_Responsavel__c = execs[1].Id));
    }
    Test.stopTest();
    Assert.isTrue(contem(erro, MSG_EXECUTIVO), 'Usuário sem papel deve ser recusado. Obtido: ' + erro);
    Assert.areEqual(execs[0].Id, executivoAtual(l.Id), 'O Executivo original deve permanecer.');
  }

  // T6. Diretora (papel Diretoria_SCO): troca e apaga o Executivo, salva.
  @IsTest
  static void t6DiretoraTrocaExecutivoSalva() {
    User b = bdr();
    User dir = diretora();
    List<User> execs = usuarios(2);
    Lead l = leadScoDoBdr(b, 'T6');
    System.runAs(b) {
      update new Lead(Id = l.Id, SCO_Executivo_Responsavel__c = execs[0].Id);
    }
    String erroTroca;
    String erroApaga;
    Id depoisDaTroca;
    Test.startTest();
    System.runAs(dir) {
      erroTroca = erroAoAtualizar(new Lead(Id = l.Id, SCO_Executivo_Responsavel__c = execs[1].Id));
      depoisDaTroca = executivoAtual(l.Id);
      erroApaga = erroAoAtualizar(new Lead(Id = l.Id, SCO_Executivo_Responsavel__c = null));
    }
    Test.stopTest();
    Assert.isNull(erroTroca, 'A Diretora deve conseguir trocar. Obtido: ' + erroTroca);
    Assert.areEqual(execs[1].Id, depoisDaTroca, 'O novo Executivo deve ficar gravado.');
    Assert.isNull(erroApaga, 'A Diretora deve conseguir apagar. Obtido: ' + erroApaga);
    Assert.isNull(executivoAtual(l.Id), 'O Executivo deve ficar vazio.');
  }

  // T7. Regressão: "Novo" -> "Em contato" pelo BDR grava o dono como BDR responsável.
  @IsTest
  static void t7BdrEmContatoGravaBdrResponsavel() {
    User b = bdr();
    Lead l = leadScoDoBdr(b, 'T7');
    Test.startTest();
    System.runAs(b) {
      update new Lead(Id = l.Id, Status = 'Em contato');
    }
    Test.stopTest();
    Assert.areEqual(b.Id, recarregar(l.Id).SCO_BDR_Responsavel__c, 'O dono deve virar BDR responsável.');
  }

  // T8. Regressão: data da reunião realizada futura é recusada para o BDR.
  @IsTest
  static void t8BdrReuniaoRealizadaFuturaRecusa() {
    User b = bdr();
    Lead l = leadScoDoBdr(b, 'T8');
    String erro;
    Test.startTest();
    System.runAs(b) {
      erro = erroAoAtualizar(new Lead(Id = l.Id, SCO_Data_Reuniao_Realizada__c = Date.today().addDays(1)));
    }
    Test.stopTest();
    Assert.isTrue(contem(erro, MSG_FUTURA), 'Data futura deve recusar. Obtido: ' + erro);
  }

  // T9. Isolamento: Lead RT SOL com Executivo trocado/apagado por usuário sem Diretoria_SCO não é bloqueado.
  // Roda como o usuário do teste (sem papel Diretoria_SCO); no RT SCO a mesma troca seria recusada.
  @IsTest
  static void t9LeadSolTrocaExecutivoSemErro() {
    User eu = [SELECT UserRole.DeveloperName FROM User WHERE Id = :UserInfo.getUserId()];
    Assert.areNotEqual(
      'Diretoria_SCO',
      eu.UserRole?.DeveloperName,
      'Pré-condição: o usuário do teste não pode ter o papel Diretoria_SCO.'
    );
    List<User> execs = usuarios(2);
    Lead l = new Lead(
      RecordTypeId = rt('SOL'),
      LastName = 'Lead 12117 T9',
      Company = 'Empresa 12117 T9',
      LeadSource = 'Indicacao',
      CNPJ__c = '11222333000181',
      Status = 'Novo',
      SCO_Executivo_Responsavel__c = execs[0].Id
    );
    insert l;
    Test.startTest();
    String erroTroca = erroAoAtualizar(new Lead(Id = l.Id, SCO_Executivo_Responsavel__c = execs[1].Id));
    String erroApaga = erroAoAtualizar(new Lead(Id = l.Id, SCO_Executivo_Responsavel__c = null));
    Test.stopTest();
    Assert.isNull(erroTroca, 'A VR SCO não pode disparar no RT SOL (troca). Obtido: ' + erroTroca);
    Assert.isNull(erroApaga, 'A VR SCO não pode disparar no RT SOL (apagar). Obtido: ' + erroApaga);
  }

  // T10. Volume: 200 Leads SCO do BDR para "Reunião agendada" com data, sem erro.
  @IsTest
  static void t10VolumeReuniaoAgendadaComData() {
    User b = bdr();
    List<Lead> leads = new List<Lead>();
    for (Integer i = 0; i < 200; i++) {
      leads.add(
        new Lead(
          RecordTypeId = rt('SCO'),
          LastName = 'Lead 12117 Vol ' + i,
          Company = 'Empresa 12117 Vol ' + i,
          LeadSource = 'Indicacao',
          Status = 'Novo'
        )
      );
    }
    System.runAs(b) {
      insert leads;
    }
    Datetime quando = System.now().addDays(5);
    for (Lead l : leads) {
      l.Status = 'Reunião agendada';
      l.SCO_Data_Reuniao_Agendada__c = quando;
    }
    Test.startTest();
    System.runAs(b) {
      update leads;
    }
    Test.stopTest();
    Assert.areEqual(
      200,
      [SELECT COUNT() FROM Lead WHERE Id IN :leads AND Status = 'Reunião agendada' AND SCO_Data_Reuniao_Agendada__c != NULL],
      'Os 200 Leads devem estar em Reunião agendada com data.'
    );
  }
}
