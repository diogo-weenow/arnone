/**
 * CLICKUP-12116 — US-02 Entrada de Leads (delta v4): duplicidade por e-mail no Lead S Company.
 *
 * Cobre a SCO_Lead_Email_Duplicate_Rule (aviso sem bloqueio, Lead x Lead pelo Email exato,
 * filtrada por record type S.Company OU Unidade de origem S.Company), a desativação da
 * SCO_Lead_CNPJ_Duplicate_Rule (mesmo CNPJ é permitido) e a regressão da VR SCO_Lead_Exige_Origem.
 *
 * Por que DuplicateRuleHeader.allowSave = false: a regra é "Allow + Alert". Na tela isso é um
 * aviso; em Apex/API, com allowSave = false, o aviso volta como Database.DuplicateError e o
 * registro não é salvo. É a forma de medir que a regra disparou sem depender de UI.
 *
 * Tudo roda como um BDR S Company (Standard User + PS_SCO_Comercial + PS_SCO_Importar_Leads,
 * papel Comercial_SCO), porque a regra usa EnforceSharingRules: só enxerga o que o usuário vê.
 */
@IsTest
private class SCOEntradaLeadTest {
  private static final String REGRA_EMAIL = 'SCO_Lead_Email_Duplicate_Rule';
  private static final String REGRA_CNPJ = 'SCO_Lead_CNPJ_Duplicate_Rule';
  private static final String AVISO = 'Já existe um Lead com este e-mail. Confira o registro existente antes de seguir.';
  private static final String MSG_ORIGEM = 'Informe a Origem do Lead.';
  private static final String USERNAME_PREFIXO = 'sco.entrada.12116.';
  private static final String CNPJ = '11222333000181';

  @TestSetup
  static void setup() {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Profile padrao = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
      UserRole papel = [SELECT Id FROM UserRole WHERE DeveloperName = 'Comercial_SCO' LIMIT 1];
      String unico = String.valueOf(Math.abs(Crypto.getRandomInteger()));
      User bdr = new User(
        FirstName = 'BDR',
        LastName = 'SCO 12116',
        CommunityNickname = ('bdrsco12116' + unico).left(40),
        Alias = 'bdr12116',
        Email = 'bdr.sco.12116@arnone.invalid',
        Username = USERNAME_PREFIXO + unico + '@arnone.test.invalid',
        ProfileId = padrao.Id,
        UserRoleId = papel.Id,
        TimeZoneSidKey = 'America/Sao_Paulo',
        LocaleSidKey = 'pt_BR',
        EmailEncodingKey = 'UTF-8',
        LanguageLocaleKey = 'pt_BR'
      );
      insert bdr;

      List<PermissionSetAssignment> psas = new List<PermissionSetAssignment>();
      for (PermissionSet ps : [
        SELECT Id
        FROM PermissionSet
        WHERE Name IN ('PS_SCO_Comercial', 'PS_SCO_Importar_Leads')
      ]) {
        psas.add(new PermissionSetAssignment(AssigneeId = bdr.Id, PermissionSetId = ps.Id));
      }
      Assert.areEqual(2, psas.size(), 'Os dois permission sets da persona BDR S Company devem existir.');
      insert psas;
    }
  }

  // ============================================================ helpers

  private static User bdr() {
    String filtro = USERNAME_PREFIXO + '%';
    return [SELECT Id FROM User WHERE Username LIKE :filtro LIMIT 1];
  }

  private static Id rt(String devName) {
    return Schema.SObjectType.Lead.getRecordTypeInfosByDeveloperName().get(devName).getRecordTypeId();
  }

  /**
   * Lead S Company valido. Nome e empresa derivam da chave para nao casar com a
   * Standard_Lead_Duplicate_Rule (nome/empresa fuzzy) e isolar a regra por e-mail.
   * @param chave identificador do Lead no cenario (ex.: Alfa, Zulu)
   * @param email e-mail do Lead (pode ser nulo)
   * @return Lead ainda nao inserido
   */
  private static Lead leadSco(String chave, String email) {
    return new Lead(
      RecordTypeId = rt('SCO'),
      FirstName = chave,
      LastName = 'Lead ' + chave,
      Company = 'Empresa ' + chave + ' Ltda',
      Email = email,
      LeadSource = 'Indicacao',
      Status = 'Novo'
    );
  }

  private static Database.DMLOptions semSalvarDuplicado() {
    Database.DMLOptions opts = new Database.DMLOptions();
    opts.DuplicateRuleHeader.allowSave = false;
    return opts;
  }

  /**
   * Erros de duplicidade de uma regra especifica, com a mensagem exibida ao usuario.
   * @param sr resultado do DML
   * @param regra DeveloperName da DuplicateRule
   * @return erros de duplicidade daquela regra
   */
  private static List<Database.DuplicateError> errosDaRegra(Database.SaveResult sr, String regra) {
    List<Database.DuplicateError> achados = new List<Database.DuplicateError>();
    for (Database.Error e : sr.getErrors()) {
      if (e instanceof Database.DuplicateError) {
        Database.DuplicateError de = (Database.DuplicateError) e;
        if (de.getDuplicateResult().getDuplicateRule() == regra) {
          achados.add(de);
        }
      }
    }
    return achados;
  }

  private static String descreverErros(Database.SaveResult sr) {
    List<String> partes = new List<String>();
    for (Database.Error e : sr.getErrors()) {
      String regra = e instanceof Database.DuplicateError
        ? ((Database.DuplicateError) e).getDuplicateResult().getDuplicateRule()
        : String.valueOf(e.getStatusCode());
      partes.add(regra + ': ' + e.getMessage());
    }
    return String.join(partes, ' | ');
  }

  // ============================================================ cenários

  // T1. Lead SCO novo com o e-mail de outro Lead SCO aberto -> aviso da regra por e-mail.
  @IsTest
  static void t1NovoComEmailRepetidoAvisa() {
    System.runAs(bdr()) {
      insert leadSco('Alfa', 'repetido.t1@scoteste.invalid');

      Test.startTest();
      Database.SaveResult sr = Database.insert(
        leadSco('Zulu', 'repetido.t1@scoteste.invalid'),
        semSalvarDuplicado()
      );
      Test.stopTest();

      Assert.isFalse(sr.isSuccess(), 'Com allowSave = false o duplicado não pode ser salvo.');
      List<Database.DuplicateError> erros = errosDaRegra(sr, REGRA_EMAIL);
      Assert.areEqual(1, erros.size(), 'Esperado aviso da ' + REGRA_EMAIL + '. Veio: ' + descreverErros(sr));
      Assert.areEqual(AVISO, erros[0].getMessage(), 'Texto do aviso diferente do decidido.');
      Assert.areEqual(
        1,
        erros[0].getDuplicateResult().getMatchResults()[0].getSize(),
        'O aviso deve apontar exatamente o Lead existente.'
      );
    }
  }

  // T2. Lead SCO editado para um e-mail que já existe em outro Lead SCO aberto -> aviso.
  @IsTest
  static void t2EdicaoParaEmailExistenteAvisa() {
    System.runAs(bdr()) {
      insert leadSco('Alfa', 'existente.t2@scoteste.invalid');
      Lead outro = leadSco('Zulu', 'diferente.t2@scoteste.invalid');
      insert outro;

      Test.startTest();
      Database.SaveResult sr = Database.update(
        new Lead(Id = outro.Id, Email = 'existente.t2@scoteste.invalid'),
        semSalvarDuplicado()
      );
      Test.stopTest();

      Assert.isFalse(sr.isSuccess(), 'Com allowSave = false a edição duplicada não pode ser salva.');
      List<Database.DuplicateError> erros = errosDaRegra(sr, REGRA_EMAIL);
      Assert.areEqual(1, erros.size(), 'Esperado aviso na edição. Veio: ' + descreverErros(sr));
      Assert.areEqual(AVISO, erros[0].getMessage(), 'Texto do aviso diferente do decidido.');
      Assert.areEqual(
        'diferente.t2@scoteste.invalid',
        [SELECT Email FROM Lead WHERE Id = :outro.Id].Email,
        'O e-mail não pode ter sido alterado.'
      );
    }
  }

  // T3. Dois Leads SCO com o mesmo CNPJ e e-mails diferentes -> ambos salvam, sem aviso.
  @IsTest
  static void t3MesmoCnpjEmailsDiferentesSalva() {
    System.runAs(bdr()) {
      Lead primeiro = leadSco('Alfa', 'cnpj.a.t3@scoteste.invalid');
      primeiro.CNPJ__c = CNPJ;
      insert primeiro;

      Lead segundo = leadSco('Zulu', 'cnpj.b.t3@scoteste.invalid');
      segundo.CNPJ__c = CNPJ;

      Test.startTest();
      Database.SaveResult sr = Database.insert(segundo, semSalvarDuplicado());
      Test.stopTest();

      Assert.isTrue(sr.isSuccess(), 'Mesmo CNPJ deve ser permitido na v4. Veio: ' + descreverErros(sr));
      Assert.areEqual(0, errosDaRegra(sr, REGRA_CNPJ).size(), 'A regra por CNPJ deve estar desativada.');
      Assert.areEqual(2, [SELECT COUNT() FROM Lead WHERE CNPJ__c = :CNPJ], 'Os dois Leads devem existir.');
    }
  }

  // T4. Lead SCO sem e-mail, com outro também sem e-mail -> salva (vazio nunca é duplicado).
  @IsTest
  static void t4SemEmailNaoEDuplicado() {
    System.runAs(bdr()) {
      insert leadSco('Alfa', null);

      Test.startTest();
      Database.SaveResult sr = Database.insert(
        leadSco('Zulu', null),
        semSalvarDuplicado()
      );
      Test.stopTest();

      Assert.isTrue(sr.isSuccess(), 'E-mail vazio não pode contar como duplicado. Veio: ' + descreverErros(sr));
      Assert.areEqual(0, errosDaRegra(sr, REGRA_EMAIL).size(), 'A regra por e-mail não pode disparar.');
    }
  }

  // T5. Lead RT SOL com o e-mail de um Lead SCO -> a regra SCO não dispara (filtro do registro salvo).
  @IsTest
  static void t5LeadSolNaoDisparaRegraSco() {
    System.runAs(bdr()) {
      insert leadSco('Alfa', 'compartilhado.t5@scoteste.invalid');
    }
    // O BDR S Company não tem o RT SOL; o Lead SOL é criado pelo usuário de contexto.
    Lead sol = new Lead(
      RecordTypeId = rt('SOL'),
      FirstName = 'Zulu',
      LastName = 'Solucoes',
      Company = 'Organizacao Zulu SA',
      Email = 'compartilhado.t5@scoteste.invalid',
      Status = 'Recebido - MQL',
      CNPJ__c = CNPJ
    );

    Test.startTest();
    Database.SaveResult sr = Database.insert(sol, semSalvarDuplicado());
    Test.stopTest();

    Assert.areEqual(
      0,
      errosDaRegra(sr, REGRA_EMAIL).size(),
      'A regra S Company não pode disparar para Lead SOL. Veio: ' + descreverErros(sr)
    );
    Assert.isTrue(sr.isSuccess(), 'Lead SOL deve salvar. Veio: ' + descreverErros(sr));
  }

  // T6. Lead criado só com Unidade de origem = SCO (sem RT, como no Web-to-Lead) e e-mail repetido -> dispara.
  @IsTest
  static void t6SoUnidadeOrigemDispara() {
    System.runAs(bdr()) {
      insert leadSco('Alfa', 'unidade.t6@scoteste.invalid');

      Lead semRt = new Lead(
        FirstName = 'Zulu',
        LastName = 'Segundo',
        Company = 'Organizacao Zulu SA',
        Email = 'unidade.t6@scoteste.invalid',
        LeadSource = 'Indicacao',
        Unidade_Origem__c = 'SCO'
      );

      Test.startTest();
      Database.SaveResult sr = Database.insert(semRt, semSalvarDuplicado());
      Test.stopTest();

      Assert.isFalse(sr.isSuccess(), 'Com allowSave = false o duplicado não pode ser salvo.');
      List<Database.DuplicateError> erros = errosDaRegra(sr, REGRA_EMAIL);
      Assert.areEqual(1, erros.size(), 'Esperado aviso pelo filtro de Unidade de origem. Veio: ' + descreverErros(sr));
      Assert.areEqual(AVISO, erros[0].getMessage(), 'Texto do aviso diferente do decidido.');
    }
  }

  // T7. Regressão CLICKUP-11811: Lead SCO sem LeadSource continua bloqueado pela VR.
  @IsTest
  static void t7SemOrigemContinuaBloqueado() {
    System.runAs(bdr()) {
      Lead semOrigem = leadSco('Alfa', 'origem.t7@scoteste.invalid');
      semOrigem.LeadSource = null;

      Test.startTest();
      Database.SaveResult sr = Database.insert(semOrigem, false);
      Test.stopTest();

      Assert.isFalse(sr.isSuccess(), 'Lead SCO sem Origem deve ser recusado.');
      Assert.isTrue(
        descreverErros(sr).contains(MSG_ORIGEM),
        'Esperado "' + MSG_ORIGEM + '". Veio: ' + descreverErros(sr)
      );
    }
  }

  // T8. Volume: 200 Leads SCO com e-mails distintos, allowSave = true -> 200 inseridos.
  @IsTest
  static void t8VolumeDuzentosLeads() {
    System.runAs(bdr()) {
      List<Lead> lote = new List<Lead>();
      for (Integer i = 0; i < 200; i++) {
        lote.add(
          leadSco('Vol' + i, 'volume.' + i + '.t8@scoteste.invalid')
        );
      }
      Database.DMLOptions opts = new Database.DMLOptions();
      opts.DuplicateRuleHeader.allowSave = true;

      Test.startTest();
      List<Database.SaveResult> resultados = Database.insert(lote, opts);
      Test.stopTest();

      Integer ok = 0;
      for (Database.SaveResult sr : resultados) {
        if (sr.isSuccess()) {
          ok++;
        }
      }
      Assert.areEqual(200, ok, 'Os 200 Leads com e-mails distintos devem ser inseridos.');
      Assert.areEqual(
        200,
        [SELECT COUNT() FROM Lead WHERE Email LIKE 'volume.%.t8@scoteste.invalid'],
        'Os 200 Leads devem estar gravados.'
      );
    }
  }
}
