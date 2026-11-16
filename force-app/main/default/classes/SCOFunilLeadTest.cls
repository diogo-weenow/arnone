/**
 * CLICKUP-11812 — Funil de status do Lead da S Company (Captacao_SCO).
 * Cobre o Flow SCO_Definir_BDR_Responsavel e as VRs SCO_Reuniao_Agendada_Exige_Dados
 * e SCO_Reuniao_Realizada_Nao_Futura, além do isolamento das outras unidades.
 */
@IsTest
private class SCOFunilLeadTest {
  private static final String MSG_REUNIAO = 'Informe o Executivo responsável e a data da reunião.';
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
    update new Lead(Id = l.Id, Status = 'Em nutrição');
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

  // 3. "Reunião agendada" exige Executivo responsável e data da reunião.
  @IsTest
  static void reuniaoAgendadaExigeDados() {
    User u = usuarios(1)[0];
    Lead l = leadSco(u.Id);

    Test.startTest();
    String semNada = erroAoAtualizar(new Lead(Id = l.Id, Status = 'Reunião agendada'));
    String semData = erroAoAtualizar(
      new Lead(Id = l.Id, Status = 'Reunião agendada', SCO_Executivo_Responsavel__c = u.Id)
    );
    String completo = erroAoAtualizar(
      new Lead(
        Id = l.Id,
        Status = 'Reunião agendada',
        SCO_Executivo_Responsavel__c = u.Id,
        SCO_Data_Reuniao_Agendada__c = System.now().addDays(2)
      )
    );
    Test.stopTest();

    System.assert(semNada != null && semNada.contains(MSG_REUNIAO), semNada);
    System.assert(semData != null && semData.contains(MSG_REUNIAO), semData);
    System.assertEquals(null, completo, 'Com os dois campos o save passa.');
    System.assertEquals('Reunião agendada', recarregar(l.Id).Status);
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
    update new Lead(Id = l.Id, Status = 'Desqualificado');
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
}
