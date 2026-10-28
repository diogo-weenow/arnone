/**
 * ACESSO-POR-BU — Testes do modelo de acesso a Lead, Oportunidade, Conta e
 * Contato por unidade de negócio.
 *
 * Mecanismos sob teste (todos já implantados na org):
 *   - OWD Lead e Opportunity Private, Account ReadWrite, Contact ControlledByParent;
 *   - papéis Diretoria_<BU> abaixo de Diretoria_Grupo, com a equipe da BU abaixo;
 *   - sharing rules por critério Lead_<BU>_BU e Opp_<BU>_BU (Edit para
 *     RoleAndSubordinatesInternal Diretoria_<BU>, label do record type);
 *   - PSGs por cargo e PS_Diretor_Global (View All em Lead e Opportunity);
 *   - custom permission Ver_Historico só nos PSGs de diretor.
 *
 * Toda leitura é em AccessLevel.USER_MODE dentro de System.runAs, que aplica
 * sharing e permissão do usuário.
 *
 * LIMITE MEDIDO: regra de compartilhamento por CRITERIO nao e calculada em
 * teste Apex (o colega da mesma BU nao enxerga o registro aqui, mas enxerga na
 * org). Por isso os positivos que dependem de Lead_<BU>_BU / Opp_<BU>_BU
 * (colega da BU, fila, upload Lemit) sao provados no E2E da org com
 * UserRecordAccess dos usuarios reais. Aqui ficam hierarquia, View All,
 * negativos entre BUs, Conta/Contato, conversao e custom permissions. Todos os usuários e registros são criados
 * aqui; papéis, PSGs e record types são resolvidos por DeveloperName.
 */
@IsTest
private class AcessoPorBUTest {
  private static final String PREFIXO = 'APB_BU';
  private static final String CNPJ_LEMIT = '11222333000181';

  // ============================================================ semeadura

  @TestSetup
  static void semear() {
    List<User> usuarios = new List<User>{
      novoUsuario('advat', 'Comercial_ADV'),
      novoUsuario('advat2', 'Comercial_ADV'),
      novoUsuario('advdir', 'Diretoria_ADV'),
      novoUsuario('solat', 'Comercial_SOL'),
      novoUsuario('solat2', 'Comercial_SOL'),
      novoUsuario('soldir', 'Diretoria_SOL'),
      novoUsuario('steat', 'Comercial_STE'),
      novoUsuario('stedir', 'Diretoria_STE'),
      novoUsuario('esgat', 'Comercial_ESG'),
      novoUsuario('esgdir', 'Diretoria_ESG'),
      novoUsuario('scoat', 'Comercial_SCO'),
      novoUsuario('scodir', 'Diretoria_SCO'),
      novoUsuario('global', 'Diretoria_Grupo')
    };
    insert usuarios;
    Map<String, Id> ids = new Map<String, Id>();
    for (User u : usuarios) {
      ids.put(u.LastName.removeStart('Bu '), u.Id);
    }

    licencasSTE(new List<Id>{ ids.get('steat'), ids.get('stedir') });

    Map<String, String> psgPorUsuario = new Map<String, String>{
      'advat' => 'PSG_ADV_Atendente',
      'advat2' => 'PSG_ADV_Atendente',
      'advdir' => 'PSG_ADV_Diretor',
      'solat' => 'PSG_SOL_Comercial',
      'solat2' => 'PSG_SOL_Comercial',
      'soldir' => 'PSG_SOL_Diretor',
      'steat' => 'PSG_STE_Atendente',
      'stedir' => 'PSG_STE_Diretor',
      'esgat' => 'PSG_ESG_Atendente',
      'esgdir' => 'PSG_ESG_Diretor',
      'scoat' => 'PSG_SCO_Atendente',
      'scodir' => 'PSG_SCO_Diretor',
      'global' => 'PSG_Diretor_Global'
    };
    Map<String, Id> psgIds = new Map<String, Id>();
    for (PermissionSetGroup g : [
      SELECT Id, DeveloperName
      FROM PermissionSetGroup
      WHERE DeveloperName IN :psgPorUsuario.values()
    ]) {
      psgIds.put(g.DeveloperName, g.Id);
    }
    List<PermissionSetAssignment> psas = new List<PermissionSetAssignment>();
    for (String apelido : psgPorUsuario.keySet()) {
      psas.add(
        new PermissionSetAssignment(
          AssigneeId = ids.get(apelido),
          PermissionSetGroupId = psgIds.get(psgPorUsuario.get(apelido))
        )
      );
    }
    insert psas;

    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Caso Robson: cadastro único. Conta e Contato da ADV, Opp ADV de 2 mi.
      Account robson = new Account(
        Name = PREFIXO + ' Robson Teste Ltda',
        OwnerId = ids.get('advat')
      );
      insert robson;
      insert new Contact(
        LastName = PREFIXO + ' Robson',
        AccountId = robson.Id,
        OwnerId = ids.get('advat')
      );
      insert new Opportunity(
        Name = PREFIXO + ' Robson US$2M',
        AccountId = robson.Id,
        OwnerId = ids.get('advat'),
        RecordTypeId = rtOpp('ADV'),
        StageName = 'Oportunidade Recebida',
        CloseDate = Date.today().addDays(30),
        Amount = 2000000
      );

      Account contaOpps = new Account(Name = PREFIXO + ' Conta das Opps');
      insert contaOpps;
      insert new List<Opportunity>{
        novaOpp('SOL', 'Diagnóstico', ids.get('solat2'), contaOpps.Id),
        novaOpp('STE_Telecom', 'Verificação de Antecedentes', ids.get('steat'), contaOpps.Id)
      };
    }

    // Cada atendente cria o Lead da propria BU (o perfil do admin nao tem os
    // record types de Lead ADV/ESG/SCO nem de Opp ESG/SCO). Isso tambem prova
    // que o atendente consegue criar registros da sua BU.
    Map<String, String> criadorPorRt = new Map<String, String>{
      'ADV' => 'advat',
      'SOL' => 'solat2',
      'STE' => 'steat',
      'ESG' => 'esgat',
      'SCO' => 'scoat'
    };
    Id contaOppsId = [SELECT Id FROM Account WHERE Name = :(PREFIXO + ' Conta das Opps')].Id;
    for (String rt : criadorPorRt.keySet()) {
      Id dono = ids.get(criadorPorRt.get(rt));
      System.runAs(new User(Id = dono)) {
        insert novoLead(rt, dono);
        if (rt == 'ESG' || rt == 'SCO') {
          insert novaOpp(rt, 'Diagnóstico', dono, contaOppsId);
        }
      }
    }
    // O rodizio SOL (e outras automacoes de entrada) pode trocar o dono na
    // criacao; o cenario precisa do dono definido, entao fixa depois.
    // Dentro de runAs: a mesma transacao ja fez DML de setup (User, PSA).
    System.runAs(new User(Id = UserInfo.getUserId())) {
      List<Lead> fixar = new List<Lead>();
      for (Lead l : [SELECT Id, LastName FROM Lead WHERE LastName LIKE :(PREFIXO + ' Lead %')]) {
        fixar.add(new Lead(Id = l.Id, OwnerId = ids.get(criadorPorRt.get(l.LastName.substringAfterLast(' ')))));
      }
      update fixar;
    }
  }

  // ============================================================ helpers

  private static User novoUsuario(String apelido, String papel) {
    Profile padrao = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
    UserRole role = [SELECT Id FROM UserRole WHERE DeveloperName = :papel LIMIT 1];
    String unico = String.valueOf(Math.abs(Crypto.getRandomInteger()));
    return new User(
      FirstName = 'APB',
      LastName = 'Bu ' + apelido,
      CommunityNickname = ('apbbu' + apelido + unico).left(40),
      Alias = ('ab' + apelido).left(8),
      Email = 'apb.' + apelido + '@arnone.invalid',
      Username = 'apb.bu.' + apelido + unico + '@arnone.acessoporbu.test.invalid',
      ProfileId = padrao.Id,
      UserRoleId = role.Id,
      Department = papel.substringAfter('_').left(3) == 'Gru' ? null : papel.substringAfter('_').left(3),
      TimeZoneSidKey = 'America/Sao_Paulo',
      LocaleSidKey = 'pt_BR',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'pt_BR'
    );
  }

  private static void licencasSTE(List<Id> userIds) {
    List<PermissionSetLicenseAssign> psl = new List<PermissionSetLicenseAssign>();
    for (PermissionSetLicense l : [
      SELECT Id
      FROM PermissionSetLicense
      WHERE DeveloperName IN ('DEUnlimitedAccessPsl', 'EmbeddedServiceMessagingUserPsl')
    ]) {
      for (Id u : userIds) {
        psl.add(new PermissionSetLicenseAssign(AssigneeId = u, PermissionSetLicenseId = l.Id));
      }
    }
    insert psl;
  }

  private static Id rtLead(String dev) {
    return Schema.SObjectType.Lead.getRecordTypeInfosByDeveloperName().get(dev).getRecordTypeId();
  }

  private static Id rtOpp(String dev) {
    return Schema.SObjectType.Opportunity.getRecordTypeInfosByDeveloperName().get(dev).getRecordTypeId();
  }

  private static String statusPadrao() {
    return [SELECT ApiName FROM LeadStatus WHERE IsDefault = TRUE LIMIT 1].ApiName;
  }

  private static Lead novoLead(String rt, Id dono) {
    Lead l = new Lead(
      LastName = PREFIXO + ' Lead ' + rt,
      Company = PREFIXO + ' Empresa ' + rt,
      RecordTypeId = rtLead(rt),
      OwnerId = dono,
      Status = statusPadrao()
    );
    if (rt == 'SOL') {
      l.put('CNPJ__c', CNPJ_LEMIT);
    }
    return l;
  }

  private static Opportunity novaOpp(String rt, String etapa, Id dono, Id contaId) {
    return new Opportunity(
      Name = PREFIXO + ' Opp ' + rt,
      AccountId = contaId,
      OwnerId = dono,
      RecordTypeId = rtOpp(rt),
      StageName = etapa,
      CloseDate = Date.today().addDays(30)
    );
  }

  private static User usuario(String apelido) {
    return [
      SELECT Id
      FROM User
      WHERE LastName = :('Bu ' + apelido) AND FirstName = 'APB'
      LIMIT 1
    ];
  }

  private static Set<String> leadsVisiveis() {
    Set<String> r = new Set<String>();
    for (Lead l : (List<Lead>) Database.query(
      'SELECT LastName FROM Lead WHERE LastName LIKE \'' + PREFIXO + '%\'',
      AccessLevel.USER_MODE
    )) {
      r.add(l.LastName.removeStart(PREFIXO + ' Lead '));
    }
    return r;
  }

  private static Set<String> oppsVisiveis() {
    Set<String> r = new Set<String>();
    for (Opportunity o : (List<Opportunity>) Database.query(
      'SELECT Name FROM Opportunity WHERE Name LIKE \'' + PREFIXO + '%\'',
      AccessLevel.USER_MODE
    )) {
      r.add(o.Name.removeStart(PREFIXO + ' ').removeStart('Opp '));
    }
    return r;
  }

  private static Lead lead(String rt) {
    return [SELECT Id FROM Lead WHERE LastName = :(PREFIXO + ' Lead ' + rt) LIMIT 1];
  }

  private static Opportunity opp(String nome) {
    return [SELECT Id FROM Opportunity WHERE Name = :(PREFIXO + ' ' + nome) LIMIT 1];
  }

  /** Conversao com o sharing do usuario corrente, como na tela. */
  private with sharing class ConversorComoUsuario {
    Database.LeadConvertResult converter(Id leadId, Id contaId) {
      Database.LeadConvert lc = new Database.LeadConvert();
      lc.setLeadId(leadId);
      lc.setAccountId(contaId);
      lc.setConvertedStatus(
        [SELECT ApiName FROM LeadStatus WHERE IsConverted = TRUE LIMIT 1].ApiName
      );
      return Database.convertLead(lc);
    }
  }

  // ============================================================ 1. Robson

  @IsTest
  static void robsonAtendenteSOLVeEditaContaEContatoMasNaoAOppADV() {
    Account conta = [SELECT Id FROM Account WHERE Name = :(PREFIXO + ' Robson Teste Ltda')];
    Contact contato = [SELECT Id FROM Contact WHERE LastName = :(PREFIXO + ' Robson')];
    Integer contas;
    Integer contatos;
    Set<String> opps;
    System.runAs(usuario('solat')) {
      contas = Database.query('SELECT Id FROM Account WHERE Id = \'' + conta.Id + '\'', AccessLevel.USER_MODE).size();
      contatos = Database.query('SELECT Id FROM Contact WHERE Id = \'' + contato.Id + '\'', AccessLevel.USER_MODE).size();
      opps = oppsVisiveis();
      Database.update(new Account(Id = conta.Id, Name = PREFIXO + ' Robson editado pelo SOL'), AccessLevel.USER_MODE);
      Database.update(new Contact(Id = contato.Id, FirstName = 'EditadoSOL'), AccessLevel.USER_MODE);
    }
    Assert.areEqual(1, contas, 'Conta e publica (OWD Edit): o atendente SOL tem de ver a Conta Robson.');
    Assert.areEqual(1, contatos, 'Contato ControlledByParent: o atendente SOL tem de ver o Contato Robson.');
    Assert.isFalse(opps.contains('Robson US$2M'), 'A Opp ADV do Robson NAO pode aparecer para o SOL. Vistas: ' + opps);
    Assert.areEqual(
      PREFIXO + ' Robson editado pelo SOL',
      [SELECT Name FROM Account WHERE Id = :conta.Id].Name,
      'O atendente SOL edita a Conta da ADV.'
    );
    Assert.areEqual('EditadoSOL', [SELECT FirstName FROM Contact WHERE Id = :contato.Id].FirstName, 'O atendente SOL edita o Contato.');
  }

  @IsTest
  static void robsonAtendenteSOLConverteLeadNaContaDaADV() {
    Account conta = [SELECT Id FROM Account WHERE Name = :(PREFIXO + ' Robson Teste Ltda')];
    Id leadId = lead('SOL').Id;
    // Dono = o proprio atendente: a regra por criterio nao e calculada em
    // teste Apex, e o que se mede aqui e a conversao na Conta de outra BU.
    // A validation rule da BU exige procuracao recebida para converter.
    update new Lead(Id = leadId, OwnerId = usuario('solat').Id, SOL_Status_Procuracao__c = 'Recebida');

    Database.LeadConvertResult res;
    Test.startTest();
    System.runAs(usuario('solat')) {
      res = new ConversorComoUsuario().converter(leadId, conta.Id);
    }
    Test.stopTest();

    Assert.isTrue(res.isSuccess(), 'O atendente SOL tem de converter o Lead SOL na Conta existente da ADV: ' + res.getErrors());
    Assert.areEqual(conta.Id, res.getAccountId(), 'A conversao tem de usar a Conta Robson existente (cadastro unico).');
    // A conversao padrao cria a Opp SEM record type (documentado em
    // SOL_ConverterLead.avancarOportunidade, que grava o RT SOL logo depois).
    // Sem RT nenhuma regra Opp_<BU>_BU casa: so dono, hierarquia e Diretor Global.
    Assert.isNull(
      [SELECT RecordTypeId FROM Opportunity WHERE Id = :res.getOpportunityId()].RecordTypeId,
      'Conversao padrao: Opp sem record type. Se mudar, revisar o risco registrado no pacote.'
    );
    System.runAs(usuario('solat')) {
      Database.update(new Opportunity(Id = res.getOpportunityId(), RecordTypeId = rtOpp('SOL')), AccessLevel.USER_MODE);
    }
    Opportunity criada = [SELECT Id, RecordType.DeveloperName FROM Opportunity WHERE Id = :res.getOpportunityId()];
    Integer vistaPeloADV;
    Integer vistaPeloSOL;
    String q = 'SELECT Id FROM Opportunity WHERE Id = \'' + criada.Id + '\'';
    System.runAs(usuario('advat')) {
      vistaPeloADV = Database.query(q, AccessLevel.USER_MODE).size();
    }
    System.runAs(usuario('solat')) {
      vistaPeloSOL = Database.query(q, AccessLevel.USER_MODE).size();
    }
    Assert.areEqual('SOL', criada.RecordType.DeveloperName, 'A Opp criada na conversao tem de ser da BU SOL.');
    Assert.areEqual(1, vistaPeloSOL, 'O atendente SOL ve a Opp que criou.');
    Assert.areEqual(0, vistaPeloADV, 'O atendente ADV, dono da Conta, NAO pode ver a Opp SOL criada na conversao.');
  }

  // ============================================================ 3. fila (negativo)

  @IsTest
  static void leadSOLEmFilaInvisivelAoADV() {
    // O positivo (atendente SOL ve e edita o Lead da fila) depende da regra por
    // criterio, que o Apex de teste nao calcula: e provado no E2E da org.
    Id fila = [SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName = 'Fila_Leads_SOL' LIMIT 1].Id;
    Id leadId = lead('SOL').Id;
    update new Lead(Id = leadId, OwnerId = fila);
    Set<String> adv;
    System.runAs(usuario('advat')) {
      adv = leadsVisiveis();
    }
    Assert.isFalse(adv.contains('SOL'), 'Lead SOL em fila NAO pode aparecer para o ADV. Vistos: ' + adv);
  }

  // ============================================================ 4. diretor ADV

  @IsTest
  static void diretorADVVeEEditaTudoDaADVEHistorico() {
    Set<String> leads;
    Set<String> opps;
    Boolean dirHist;
    Boolean atHist;
    Id oppId = opp('Robson US$2M').Id;
    Id leadId = lead('ADV').Id;
    System.runAs(usuario('advdir')) {
      leads = leadsVisiveis();
      opps = oppsVisiveis();
      dirHist = FeatureManagement.checkPermission('Ver_Historico');
      Database.update(new Opportunity(Id = oppId, CloseDate = Date.today().addDays(45)), AccessLevel.USER_MODE);
      Database.update(new Lead(Id = leadId, Company = PREFIXO + ' editada pelo diretor'), AccessLevel.USER_MODE);
    }
    System.runAs(usuario('advat')) {
      atHist = FeatureManagement.checkPermission('Ver_Historico');
    }
    Assert.areEqual(new Set<String>{ 'ADV' }, leads, 'Diretor ADV ve os Leads ADV e nenhum outro.');
    Assert.areEqual(new Set<String>{ 'Robson US$2M' }, opps, 'Diretor ADV ve a Opp ADV e nao a SOL.');
    Assert.areEqual(Date.today().addDays(45), [SELECT CloseDate FROM Opportunity WHERE Id = :oppId].CloseDate, 'Diretor ADV edita a Opp ADV.');
    Assert.areEqual(PREFIXO + ' editada pelo diretor', [SELECT Company FROM Lead WHERE Id = :leadId].Company, 'Diretor ADV edita o Lead ADV.');
    Assert.isTrue(dirHist, 'Diretor ADV tem Ver_Historico.');
    Assert.isFalse(atHist, 'Atendente ADV NAO tem Ver_Historico.');
  }

  // ============================================================ 5. diretor global

  @IsTest
  static void diretorGlobalVeLeadsEOppsDeTodasAsBUs() {
    Set<String> leads;
    Set<String> opps;
    Boolean hist;
    Boolean restrito;
    System.runAs(usuario('global')) {
      leads = leadsVisiveis();
      opps = oppsVisiveis();
      hist = FeatureManagement.checkPermission('Ver_Historico');
      restrito = FeatureManagement.checkPermission('Atividades_Restritas_Por_BU');
    }
    Assert.areEqual(new Set<String>{ 'ADV', 'SOL', 'STE', 'ESG', 'SCO' }, leads, 'Diretor Global ve Leads de todas as BUs.');
    Assert.areEqual(
      new Set<String>{ 'Robson US$2M', 'SOL', 'STE_Telecom', 'ESG', 'SCO' },
      opps,
      'Diretor Global ve Opps de todas as BUs.'
    );
    Assert.isTrue(hist, 'Diretor Global tem Ver_Historico.');
    Assert.isFalse(restrito, 'Diretor Global nao e restringido em atividades.');
  }

  // ============================================================ 7. personas

  @IsTest
  static void cadaPersonaVeSoASuaBU() {
    Map<String, String> buPorUsuario = new Map<String, String>{
      'advat' => 'ADV',
      'advdir' => 'ADV',
      'solat' => 'SOL',
      'soldir' => 'SOL',
      'steat' => 'STE',
      'stedir' => 'STE',
      'esgat' => 'ESG',
      'esgdir' => 'ESG',
      'scoat' => 'SCO',
      'scodir' => 'SCO'
    };
    Map<String, String> oppDaBU = new Map<String, String>{
      'ADV' => 'Robson US$2M',
      'SOL' => 'SOL',
      'STE' => 'STE_Telecom',
      'ESG' => 'ESG',
      'SCO' => 'SCO'
    };
    for (String apelido : buPorUsuario.keySet()) {
      String bu = buPorUsuario.get(apelido);
      Boolean diretor = apelido.endsWith('dir');
      Set<String> leads;
      Set<String> opps;
      Boolean hist;
      Boolean atv;
      System.runAs(usuario(apelido)) {
        leads = leadsVisiveis();
        opps = oppsVisiveis();
        hist = FeatureManagement.checkPermission('Ver_Historico');
        atv = FeatureManagement.checkPermission('Atividades_Restritas_Por_BU');
      }
      // Nenhuma persona ve registro de outra BU (vale com ou sem a regra).
      Assert.isTrue(
        new Set<String>{ bu }.containsAll(leads),
        apelido + ' nao pode ver Lead de outra BU. Vistos: ' + leads
      );
      Assert.isTrue(
        new Set<String>{ oppDaBU.get(bu) }.containsAll(opps),
        apelido + ' nao pode ver Opp de outra BU. Vistas: ' + opps
      );
      // O diretor ve toda a BU pela hierarquia: o Lead e a Opp de teste sao de
      // atendentes abaixo dele. O atendente ver o registro do colega depende da
      // regra por criterio, provada no E2E da org.
      if (diretor) {
        Assert.areEqual(new Set<String>{ bu }, leads, apelido + ' ve o Lead da BU.');
        Assert.areEqual(new Set<String>{ oppDaBU.get(bu) }, opps, apelido + ' ve a Opp da BU.');
      }
      Assert.areEqual(diretor, hist, apelido + ': Ver_Historico so para diretor.');
      // O vendedor SOL fica na regra do 9430, nao na regra por BU.
      Assert.areEqual(apelido != 'solat', atv, apelido + ': Atividades_Restritas_Por_BU.');
    }
  }
}
