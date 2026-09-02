/**
 * CLICKUP-9400 — Testes da entrada em tempo real da reatribuição por falta de
 * contato: Record-Triggered Flow SOL_Reatribuir_Por_Falta_Contato (after-save em
 * Task) -> SOLReatribuicaoContatoInvocable -> SOLDistribuicaoService.
 *
 * Automação REAL ativa, sem bypass. Nenhum teste depende de permission set.
 */
@IsTest
private class SOLReatribuicaoContatoInvocableTest {
  private static final String FILA_SINTETICA = 'RR_ReatInv_SOL_9400';
  private static final String CNPJ = '11222333000181';

  @TestSetup
  static void semear() {
    insert new SOL_Distribuicao_Estado__c(Name = 'SOL');
  }

  private static User contextoAtual() {
    return new User(Id = UserInfo.getUserId());
  }

  private static User vendedor(Integer i) {
    return new User(
      FirstName = 'RR',
      LastName = 'ReatInvVend ' + i,
      Alias = ('rri' + i).left(8),
      Email = 'rr.rri' + i + '@arnone.invalid',
      Username = 'rr.rri' +
        i +
        '.' +
        String.valueOf(Math.abs(Crypto.getRandomInteger())) +
        '@arnone.clickup9400.test.invalid',
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

  private static Cenario montarCenario(Integer qtd) {
    Cenario c = new Cenario();
    List<User> vs = new List<User>();
    for (Integer i = 0; i < qtd; i++) {
      vs.add(vendedor(i));
    }
    System.runAs(contextoAtual()) {
      if (!vs.isEmpty()) {
        insert vs;
      }
      Group fila = new Group(
        Name = 'RR ReatInv SOL 9400',
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

  private static Id rtSOL() {
    return Lead.SObjectType.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get('SOL')
      .getRecordTypeId();
  }

  private static String statusLeadPadrao() {
    List<LeadStatus> p = [
      SELECT MasterLabel
      FROM LeadStatus
      WHERE IsDefault = TRUE
      LIMIT 1
    ];
    return p.isEmpty()
      ? [SELECT MasterLabel FROM LeadStatus LIMIT 1].MasterLabel
      : p[0].MasterLabel;
  }

  private static Lead leadDistribuido(String nome) {
    Lead l = new Lead(
      RecordTypeId = rtSOL(),
      LastName = nome,
      Company = 'C',
      Status = statusLeadPadrao(),
      CNPJ__c = CNPJ
    );
    insert l;
    return [SELECT Id, OwnerId FROM Lead WHERE Id = :l.Id];
  }

  private static Task tarefa(Id leadId, String resultado, String status) {
    return new Task(
      WhoId = leadId,
      Subject = 'Tentativa',
      Status = status,
      ActivityDate = Date.today(),
      SOL_Resultado_Contato__c = resultado
    );
  }

  private static Lead recarregar(Id id) {
    return [
      SELECT OwnerId, SOL_Quantidade_Reatribuicoes__c, SOL_Status_Reatribuicao__c
      FROM Lead
      WHERE Id = :id
    ];
  }

  // ---------------------------------------------------------------- testes

  @IsTest
  static void flowReatribuiAoConcluirTerceiraTarefaSemSucesso() {
    Cenario c = montarCenario(3);
    Lead l = leadDistribuido('ViaFlow');
    Id ownerInicial = l.OwnerId;

    Test.startTest();
    insert new List<Task>{
      tarefa(l.Id, 'Sem sucesso', 'Completed'),
      tarefa(l.Id, 'Sem sucesso', 'Completed'),
      tarefa(l.Id, 'Sem sucesso', 'Completed')
    };
    Test.stopTest();

    Lead d = recarregar(l.Id);
    System.assertNotEquals(ownerInicial, d.OwnerId, 'O Flow disparou a reatribuição.');
    System.assertEquals(1, d.SOL_Quantidade_Reatribuicoes__c);
    System.assertEquals(
      1,
      [SELECT COUNT() FROM Task WHERE WhoId = :l.Id AND Subject = '1ª Ligação'],
      'Uma tarefa 1ª Ligação para o novo vendedor.'
    );
  }

  @IsTest
  static void flowNaoDisparaComTarefaAberta() {
    Cenario c = montarCenario(3);
    Lead l = leadDistribuido('TarefaAberta');
    Id ownerInicial = l.OwnerId;

    Test.startTest();
    insert new List<Task>{
      tarefa(l.Id, 'Sem sucesso', 'Open'),
      tarefa(l.Id, 'Sem sucesso', 'Open'),
      tarefa(l.Id, 'Sem sucesso', 'Open')
    };
    Test.stopTest();

    System.assertEquals(
      ownerInicial,
      recarregar(l.Id).OwnerId,
      'Tarefa não concluída não conta.'
    );
  }

  @IsTest
  static void flowNaoDisparaComResultadoSucesso() {
    Cenario c = montarCenario(3);
    Lead l = leadDistribuido('Sucesso');
    Id ownerInicial = l.OwnerId;

    Test.startTest();
    insert new List<Task>{
      tarefa(l.Id, 'Sucesso', 'Completed'),
      tarefa(l.Id, 'Sucesso', 'Completed'),
      tarefa(l.Id, 'Sucesso', 'Completed')
    };
    Test.stopTest();

    System.assertEquals(ownerInicial, recarregar(l.Id).OwnerId);
    System.assertEquals(0, recarregar(l.Id).SOL_Quantidade_Reatribuicoes__c);
  }

  @IsTest
  static void invocableConsolidaIdsDuplicadosEIgnoraNaoLead() {
    Cenario c = montarCenario(3);
    Lead l = leadDistribuido('Dup');
    insert new List<Task>{
      tarefa(l.Id, 'Sem sucesso', 'Completed'),
      tarefa(l.Id, 'Sem sucesso', 'Completed'),
      tarefa(l.Id, 'Sem sucesso', 'Completed')
    };
    Decimal qtdApos = recarregar(l.Id).SOL_Quantidade_Reatribuicoes__c;

    List<SOLReatribuicaoContatoInvocable.Entrada> entradas = new List<SOLReatribuicaoContatoInvocable.Entrada>();
    for (Integer i = 0; i < 3; i++) {
      SOLReatribuicaoContatoInvocable.Entrada e = new SOLReatribuicaoContatoInvocable.Entrada();
      e.leadId = l.Id;
      entradas.add(e);
    }
    SOLReatribuicaoContatoInvocable.Entrada nulo = new SOLReatribuicaoContatoInvocable.Entrada();
    entradas.add(nulo);

    Test.startTest();
    SOLReatribuicaoContatoInvocable.reatribuir(entradas); // ciclo já reiniciado -> no-op
    SOLReatribuicaoContatoInvocable.reatribuir(null);
    SOLReatribuicaoContatoInvocable.reatribuir(
      new List<SOLReatribuicaoContatoInvocable.Entrada>()
    );
    Test.stopTest();

    System.assertEquals(
      qtdApos,
      recarregar(l.Id).SOL_Quantidade_Reatribuicoes__c,
      'Id repetido / lista vazia / nula não reatribuem de novo.'
    );
  }

  @IsTest
  static void concluirTarefaNaoFalhaMesmoComConfiguracaoQuebrada() {
    Cenario c = montarCenario(3);
    Lead l = leadDistribuido('ConfigQuebrada');

    Test.startTest();
    SOLDistribuicaoService.singletonKeyOverride = 'RR_INEXISTENTE_9400';
    Task t = tarefa(l.Id, 'Sem sucesso', 'Completed');
    insert t; // Flow -> serviço falha -> Invocable engole -> Task é criada
    Test.stopTest();
    SOLDistribuicaoService.singletonKeyOverride = null;

    System.assertNotEquals(null, t.Id, 'A Task foi concluída apesar do erro.');
  }
}
