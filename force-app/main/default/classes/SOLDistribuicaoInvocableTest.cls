/**
 * CLICKUP-9394 — Testes da entrada em tempo real (ETAPA 5.1).
 *
 * Exercitam a via completa Record-Triggered Flow SOL_Distribuir_Lead ->
 * SOLDistribuicaoInvocable -> SOLDistribuicaoService, com a automação REAL
 * ativa (sem bypass): Lead nasce SOL, Lead muda para SOL, bulk, ausência de
 * recursão, atualização comum/de Owner não redistribui, Lead de outra BU
 * intocado, kill-switch / roster vazio -> Fallback, erro controlado não
 * bloqueia a criação e deixa o Lead na fila mesmo sem Assignment Rule.
 *
 * Nenhum teste depende de permission set: a execução interna do serviço roda
 * em contexto de sistema.
 */
@IsTest
private class SOLDistribuicaoInvocableTest {
  private static final String FILA_SINTETICA = 'RR_Inv_SOL_9394';
  private static final String CNPJ = '11222333000181';

  @TestSetup
  static void semear() {
    insert new SOL_Distribuicao_Estado__c(Name = 'SOL');
  }

  // ---------------------------------------------------------------- helpers

  private static User contextoAtual() {
    return new User(Id = UserInfo.getUserId());
  }

  private static User semPermissionSet() {
    // Usuário comum, SEM nenhum PS de distribuição — prova que o serviço roda
    // sem depender de permission set.
    List<Profile> p = [
      SELECT Id
      FROM Profile
      WHERE UserType = 'Standard'
      ORDER BY Name
      LIMIT 1
    ];
    return new User(
      FirstName = 'RR',
      LastName = 'SemPS',
      Alias = 'rrnops',
      Email = 'rr.semps@arnone.invalid',
      Username = 'rr.semps.' +
        String.valueOf(Math.abs(Crypto.getRandomInteger())) +
        '@arnone.clickup9394.test.invalid',
      ProfileId = p.isEmpty() ? UserInfo.getProfileId() : p[0].Id,
      TimeZoneSidKey = 'America/Sao_Paulo',
      LocaleSidKey = 'pt_BR',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'pt_BR',
      IsActive = true
    );
  }

  private static User vendedor(Integer i) {
    return new User(
      FirstName = 'RR',
      LastName = 'Vend ' + i,
      Alias = ('rrv' + i).left(8),
      Email = 'rr.v' + i + '@arnone.invalid',
      Username = 'rr.iv' +
        i +
        '.' +
        String.valueOf(Math.abs(Crypto.getRandomInteger())) +
        '@arnone.clickup9394.test.invalid',
      ProfileId = UserInfo.getProfileId(),
      TimeZoneSidKey = 'America/Sao_Paulo',
      LocaleSidKey = 'pt_BR',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'pt_BR',
      IsActive = true
    );
  }

  private class Cenario {
    Id filaId;
    List<Id> vendedores = new List<Id>();
  }

  private static Cenario montarCenario(Integer qtdVendedores) {
    Cenario c = new Cenario();
    List<User> vs = new List<User>();
    for (Integer i = 0; i < qtdVendedores; i++) {
      vs.add(vendedor(i));
    }
    System.runAs(contextoAtual()) {
      if (!vs.isEmpty()) {
        insert vs;
      }
      Group fila = new Group(
        Name = 'RR Inv SOL 9394',
        DeveloperName = FILA_SINTETICA,
        Type = 'Queue'
      );
      insert fila;
      insert new QueueSobject(QueueId = fila.Id, SobjectType = 'Lead');
      c.filaId = fila.Id;
      List<GroupMember> gms = new List<GroupMember>();
      for (User v : vs) {
        gms.add(new GroupMember(GroupId = fila.Id, UserOrGroupId = v.Id));
      }
      if (!gms.isEmpty()) {
        insert gms;
      }
    }
    for (User v : vs) {
      c.vendedores.add(v.Id);
    }
    c.vendedores.sort();
    SOLDistribuicaoService.queueDeveloperNameOverride = FILA_SINTETICA;
    return c;
  }

  private static Id rtLeadSOL() {
    return Lead.SObjectType.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get('SOL')
      .getRecordTypeId();
  }

  private static String statusCache;
  private static String statusLead() {
    if (statusCache == null) {
      List<LeadStatus> p = [
        SELECT MasterLabel
        FROM LeadStatus
        WHERE IsDefault = TRUE
        LIMIT 1
      ];
      statusCache = p.isEmpty()
        ? [SELECT MasterLabel FROM LeadStatus LIMIT 1].MasterLabel
        : p[0].MasterLabel;
    }
    return statusCache;
  }

  private static Lead leadSOL(String nome) {
    return new Lead(
      RecordTypeId = rtLeadSOL(),
      LastName = nome,
      Company = 'C',
      Status = statusLead(),
      CNPJ__c = CNPJ
    );
  }

  private static Lead leadSemRT(String nome) {
    return new Lead(LastName = nome, Company = 'C', Status = statusLead());
  }

  private static Lead recarregar(Id leadId) {
    return [
      SELECT
        Id,
        OwnerId,
        RecordTypeId,
        SOL_Status_Distribuicao__c,
        SOL_Data_Distribuicao__c,
        SOL_Erro_Distribuicao__c
      FROM Lead
      WHERE Id = :leadId
    ];
  }

  private static SOL_Distribuicao_Estado__c estado() {
    return [
      SELECT Ultimo_Usuario__c, Total_Distribuido__c
      FROM SOL_Distribuicao_Estado__c
      WHERE Chave__c = 'SOL'
    ];
  }

  private static void killSwitch() {
    SOL_Distribuicao_Estado__c e = [
      SELECT Id
      FROM SOL_Distribuicao_Estado__c
      WHERE Chave__c = 'SOL'
    ];
    e.Ativo__c = false;
    update e;
  }

  // ============================================================ INVOCABLE

  @IsTest
  static void invocableProcessaEmBulkSemQueryOuDmlEmLaco() {
    Cenario c = montarCenario(3);
    List<Lead> leads = new List<Lead>();
    for (Integer i = 0; i < 200; i++) {
      leads.add(leadSOL('Bulk ' + i));
    }

    Integer soql;
    Integer dml;
    Test.startTest();
    Integer q0 = Limits.getQueries();
    Integer d0 = Limits.getDmlStatements();
    insert leads; // 1 DML -> Flow agrupa -> Invocable 1x -> distribuir 1x
    soql = Limits.getQueries() - q0;
    dml = Limits.getDmlStatements() - d0;
    Test.stopTest();

    System.assert(
      soql <= 14,
      'SOQL do insert de 200 Leads não pode escalar por Lead: ' + soql
    );
    System.assert(
      dml <= 8,
      'DML do insert de 200 Leads não pode escalar por Lead: ' + dml
    );
    System.assert(
      estado().Total_Distribuido__c == 200,
      'Distribuídos numa única chamada bulk: ' + estado().Total_Distribuido__c
    );
    // CLICKUP-9396: uma Task "1ª Ligação" por Lead, mesmo com o Flow em bulk.
    System.assertEquals(
      200,
      [SELECT COUNT() FROM Task WHERE WhoId IN :leads AND Subject = '1ª Ligação']
    );
  }

  @IsTest
  static void invocableConsolidaIdsDuplicados() {
    Cenario c = montarCenario(2);
    Lead l = leadSOL('Dup');
    insert l; // Flow já distribui -> Total = 1

    List<SOLDistribuicaoInvocable.Entrada> entradas = new List<SOLDistribuicaoInvocable.Entrada>();
    for (Integer i = 0; i < 3; i++) {
      SOLDistribuicaoInvocable.Entrada e = new SOLDistribuicaoInvocable.Entrada();
      e.leadId = l.Id;
      entradas.add(e);
    }

    Test.startTest();
    SOLDistribuicaoInvocable.distribuir(entradas); // Lead já Distribuido -> no-op
    Test.stopTest();

    System.assert(
      estado().Total_Distribuido__c == 1,
      'Id repetido não redistribui: ' + estado().Total_Distribuido__c
    );
  }

  @IsTest
  static void entradaVaziaOuNulaOuSemIdNaoFazNada() {
    Cenario c = montarCenario(2);
    List<SOLDistribuicaoInvocable.Entrada> comNulo = new List<SOLDistribuicaoInvocable.Entrada>{
      new SOLDistribuicaoInvocable.Entrada()
    };
    Test.startTest();
    SOLDistribuicaoInvocable.distribuir(null);
    SOLDistribuicaoInvocable.distribuir(
      new List<SOLDistribuicaoInvocable.Entrada>()
    );
    SOLDistribuicaoInvocable.distribuir(comNulo);
    Test.stopTest();
    System.assert(estado().Total_Distribuido__c == 0);
  }

  // ============================================================ VIA FLOW

  @IsTest
  static void leadCriadoComoSOLEhDistribuido() {
    Cenario c = montarCenario(2);
    Lead l = leadSOL('NasceSOL');
    Test.startTest();
    insert l;
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertEquals('Distribuido', d.SOL_Status_Distribuicao__c);
    System.assertEquals(c.vendedores[0], d.OwnerId, 'Primeiro vendedor.');
    System.assertNotEquals(null, d.SOL_Data_Distribuicao__c);
    // CLICKUP-9396: distribuição inicial cria uma Task "1ª Ligação".
    List<Task> tks = [
      SELECT OwnerId, Status, SOL_Prazo_Contato__c
      FROM Task
      WHERE WhoId = :l.Id AND Subject = '1ª Ligação'
    ];
    System.assertEquals(1, tks.size());
    System.assertEquals(c.vendedores[0], tks[0].OwnerId);
    System.assertEquals('Open', tks[0].Status);
    System.assertNotEquals(null, tks[0].SOL_Prazo_Contato__c);
  }

  @IsTest
  static void leadCriadoPorUsuarioSemPermissionSetEhDistribuido() {
    Cenario c = montarCenario(2);
    User u = semPermissionSet();
    System.runAs(contextoAtual()) {
      insert u;
    }
    Lead l = leadSOL('SemPS');
    Test.startTest();
    System.runAs(u) {
      insert l; // Flow dispara como usuário SEM PS de distribuição
    }
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertEquals(
      'Distribuido',
      d.SOL_Status_Distribuicao__c,
      'Serviço distribui sem depender de permission set.'
    );
    System.assert(c.vendedores.contains(d.OwnerId));
  }

  @IsTest
  static void leadAlteradoDeOutroRTParaSOLEhDistribuido() {
    Cenario c = montarCenario(2);
    Lead l = leadSemRT('ViraSOL');
    insert l; // Flow não dispara (sem RT SOL)

    Test.startTest();
    update new Lead(Id = l.Id, RecordTypeId = rtLeadSOL(), CNPJ__c = CNPJ);
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertEquals('Distribuido', d.SOL_Status_Distribuicao__c);
    System.assert(c.vendedores.contains(d.OwnerId));
  }

  @IsTest
  static void atualizacaoComumEmLeadSOLNaoRedistribui() {
    Cenario c = montarCenario(3);
    Lead l = leadSOL('EdicaoComum');
    insert l;
    Id ownerApos1 = recarregar(l.Id).OwnerId;
    Decimal totalApos1 = estado().Total_Distribuido__c;

    Test.startTest();
    update new Lead(Id = l.Id, Phone = '11 90000-0000');
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertEquals(ownerApos1, d.OwnerId, 'Owner não muda.');
    System.assertEquals('Distribuido', d.SOL_Status_Distribuicao__c);
    System.assertEquals(
      totalApos1,
      estado().Total_Distribuido__c,
      'Sem nova distribuição.'
    );
    // CLICKUP-9396: atualização comum não duplica a Task "1ª Ligação".
    System.assertEquals(
      1,
      [SELECT COUNT() FROM Task WHERE WhoId = :l.Id AND Subject = '1ª Ligação'],
      'Continua com uma única Task "1ª Ligação".'
    );
  }

  @IsTest
  static void atualizacaoDeOwnerEmLeadSOLNaoRedistribui() {
    Cenario c = montarCenario(3);
    Lead l = leadSOL('TrocaOwner');
    insert l;
    Decimal totalApos1 = estado().Total_Distribuido__c;

    Id novoOwner = c.vendedores[2];
    Test.startTest();
    update new Lead(Id = l.Id, OwnerId = novoOwner);
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertEquals(novoOwner, d.OwnerId, 'Owner manual permanece.');
    System.assertEquals(totalApos1, estado().Total_Distribuido__c);
  }

  @IsTest
  static void servicoAtualizaOProprioLeadSemRecursao() {
    Cenario c = montarCenario(2);
    Lead l = leadSOL('SemRecursao');
    Integer soql;
    Test.startTest();
    Integer q0 = Limits.getQueries();
    insert l; // Flow -> serviço faz update do próprio Lead; não re-dispara
    soql = Limits.getQueries() - q0;
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertEquals('Distribuido', d.SOL_Status_Distribuicao__c);
    System.assert(
      estado().Total_Distribuido__c == 1,
      'Distribuiu 1 vez só: ' + estado().Total_Distribuido__c
    );
    System.assert(soql < 30, 'Sem explosão de SOQL por recursão: ' + soql);
  }

  @IsTest
  static void leadDeOutraBUPermaneceSemStatusSOL() {
    Cenario c = montarCenario(2);
    Lead l = leadSemRT('OutraBU');
    Test.startTest();
    insert l;
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertEquals(
      null,
      d.SOL_Status_Distribuicao__c,
      'Lead de outra BU não recebe status SOL.'
    );
    System.assert(
      !c.vendedores.contains(d.OwnerId),
      'Owner não é um vendedor do rodízio.'
    );
    System.assert(estado().Total_Distribuido__c == 0);
    System.assertEquals(
      0,
      [SELECT COUNT() FROM Task WHERE WhoId = :l.Id AND Subject = '1ª Ligação'],
      'CLICKUP-9396: Lead de outra BU não cria Task.'
    );
  }

  @IsTest
  static void killSwitchMantemLeadNaFilaComFallback() {
    Cenario c = montarCenario(2);
    Lead l = leadSOL('KillSwitch');
    Test.startTest();
    killSwitch();
    insert l;
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertEquals('Fallback', d.SOL_Status_Distribuicao__c);
    System.assertEquals(c.filaId, d.OwnerId);
    System.assertEquals(null, estado().Ultimo_Usuario__c);
  }

  @IsTest
  static void rosterVazioMantemLeadNaFilaComFallback() {
    Cenario c = montarCenario(0); // fila sem membros
    Lead l = leadSOL('RosterVazio');
    Test.startTest();
    insert l;
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertEquals('Fallback', d.SOL_Status_Distribuicao__c);
    System.assertEquals(c.filaId, d.OwnerId);
  }

  @IsTest
  static void erroControladoNaoBloqueiaCriacaoEDeixaLeadNaFila() {
    // Insert via Apex SEM DMLOptions -> a Assignment Rule NÃO roda.
    // Config quebrada -> o serviço falha -> Invocable engole -> Lead é criado
    // e o tratamento de erro o deixa na Fila_Leads_SOL.
    Cenario c = montarCenario(2);
    Lead l = leadSOL('ErroControlado');
    Test.startTest();
    SOLDistribuicaoService.singletonKeyOverride = 'RR_INEXISTENTE_9394';
    insert l;
    Test.stopTest();
    SOLDistribuicaoService.singletonKeyOverride = null;

    System.assertNotEquals(null, l.Id, 'Lead foi criado.');
    Lead d = recarregar(l.Id);
    System.assertEquals('Erro', d.SOL_Status_Distribuicao__c);
    System.assertEquals(
      c.filaId,
      d.OwnerId,
      'Falha -> Lead fica na fila (sem depender da Assignment Rule).'
    );
    System.assert(String.isNotBlank(d.SOL_Erro_Distribuicao__c));
  }
}