/**
 * CLICKUP-12011 - Funil de Oportunidade da BU Arnone Advogados (Funil_ADV).
 *
 * Testa o funil de 6 etapas que ja estava ao vivo na org e as automacoes
 * nativas que dependem dos nomes das etapas (4 Validation Rules ativas; a
 * ADV_Perdido_Exige_Motivo esta desativada pelo CLICKUP-12012) e os Flows
 * ADV_Carimbo_Envio_Proposta e ADV_Validar_Ganho_Com_Contrato). Nenhuma logica
 * de producao: so regressao do comportamento existente.
 *
 * Etapa inicial: o Salesforce nao aceita etapa default em Sales Process de
 * Oportunidade ("Cannot specify a default on: Opportunity"). Criterio ajustado
 * pelo PO: "Oportunidade Recebida" e a 1a etapa do funil e e aceita na criacao.
 *
 * As Opps sao criadas por um vendedor ADV (Standard User + PS_ADV_Comercial),
 * que e quem tem o record type ADV disponivel.
 */
@IsTest
private class ADVFunilOportunidadeTest {
  private static final String PREFIXO = 'ADVFUNIL';
  private static final List<String> ETAPAS_ADV = new List<String>{
    'Oportunidade Recebida',
    'Em Precificação',
    'Proposta Enviada',
    'Aguardando Assinatura',
    'Ganho',
    'Perdido'
  };

  @TestSetup
  static void semear() {
    // O nome do perfil vem traduzido no idioma de quem roda o teste.
    Profile padrao = [SELECT Id FROM Profile WHERE Name IN ('Standard User', 'Usuário Padrão') LIMIT 1];
    UserRole papel = [SELECT Id FROM UserRole WHERE DeveloperName = 'Comercial_ADV' LIMIT 1];
    String unico = String.valueOf(Math.abs(Crypto.getRandomInteger()));
    User vendedor = new User(
      FirstName = 'ADV',
      LastName = PREFIXO + ' Vendedor',
      CommunityNickname = ('advfunil' + unico).left(40),
      Alias = 'advfunil',
      Email = 'advfunil.vendedor@arnone.invalid',
      Username = 'advfunil.vendedor' + unico + '@arnone.advfunil.test.invalid',
      ProfileId = padrao.Id,
      UserRoleId = papel.Id,
      Department = 'ADV',
      TimeZoneSidKey = 'America/Sao_Paulo',
      LocaleSidKey = 'pt_BR',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'pt_BR'
    );
    insert vendedor;
    insert new PermissionSetAssignment(
      AssigneeId = vendedor.Id,
      PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'PS_ADV_Comercial'].Id
    );
    insert new Account(Name = PREFIXO + ' Cliente', OwnerId = vendedor.Id);
  }

  // ============================================================ metadado

  @IsTest
  static void funilTemAs6EtapasNaOrdemComAtributosCorretos() {
    List<OpportunityStage> etapas = [
      SELECT ApiName, IsClosed, IsWon, DefaultProbability, ForecastCategoryName
      FROM OpportunityStage
      WHERE ApiName IN :ETAPAS_ADV AND IsActive = TRUE
      ORDER BY SortOrder
    ];
    List<String> nomes = new List<String>();
    for (OpportunityStage e : etapas) {
      nomes.add(e.ApiName);
    }
    Assert.areEqual(ETAPAS_ADV, nomes, 'As 6 etapas ADV na ordem do funil.');

    Map<String, OpportunityStage> porNome = new Map<String, OpportunityStage>();
    for (OpportunityStage e : etapas) {
      porNome.put(e.ApiName, e);
    }
    assertEtapa(porNome.get('Oportunidade Recebida'), false, false, 30, 'Pipeline');
    assertEtapa(porNome.get('Em Precificação'), false, false, 40, 'Pipeline');
    assertEtapa(porNome.get('Proposta Enviada'), false, false, 60, 'Pipeline');
    // Categoria "Commit" (no metadado do StandardValueSet aparece como Forecast).
    assertEtapa(porNome.get('Aguardando Assinatura'), false, false, 80, 'Commit');
    assertEtapa(porNome.get('Ganho'), true, true, 100, 'Closed');
    assertEtapa(porNome.get('Perdido'), true, false, 0, 'Omitted');
  }

  // ============================================================ criacao

  @IsTest
  static void novaOppADVEAceitaEmOportunidadeRecebidaSemClassificacao() {
    Opportunity o = novaOpp('Oportunidade Recebida');
    System.runAs(vendedor()) {
      insert o;
    }
    Opportunity salva = recarregar(o.Id);
    Assert.areEqual('Oportunidade Recebida', salva.StageName);
    Assert.isFalse(salva.IsClosed);
    Assert.areEqual(30, salva.Probability, 'Probabilidade padrao da etapa.');
  }

  @IsTest
  static void plataformaExigeEtapaNaCriacao() {
    // Documenta o limite da plataforma: sem default no Sales Process, a etapa
    // tem de ser informada na criacao. Classificada para a VR de classificacao
    // nao mascarar o erro de campo obrigatorio.
    Opportunity o = classificar(novaOpp(null));
    Database.SaveResult r;
    System.runAs(vendedor()) {
      r = Database.insert(o, false);
    }
    Assert.isFalse(r.isSuccess(), 'Opp sem etapa nao pode ser salva.');
    Assert.areEqual(StatusCode.REQUIRED_FIELD_MISSING, r.getErrors()[0].getStatusCode());
  }

  // ============================================================ isolamento

  @IsTest
  static void etapaDeOutraBUNaoEAceitaNoRecordTypeADV() {
    List<Opportunity> opps = new List<Opportunity>{ novaOpp('Qualificação'), novaOpp('Diagnóstico') };
    List<Database.SaveResult> rs;
    System.runAs(vendedor()) {
      rs = Database.insert(opps, false);
    }
    for (Integer i = 0; i < rs.size(); i++) {
      Assert.isFalse(rs[i].isSuccess(), 'Etapa ' + opps[i].StageName + ' nao pertence ao Funil_ADV.');
    }
  }

  // ============================================================ VRs e Flows

  @IsTest
  static void sairDeOportunidadeRecebidaExigeAreaEAdvogado() {
    Opportunity o = novaOpp('Oportunidade Recebida');
    System.runAs(vendedor()) {
      insert o;
      o.StageName = 'Em Precificação';
      assertBloqueado(o, 'preencha a Área jurídica e o Advogado responsável');

      classificar(o);
      Test.startTest();
      update o;
      Test.stopTest();
    }
    Assert.areEqual('Em Precificação', recarregar(o.Id).StageName);
  }

  @IsTest
  static void propostaEnviadaCarimbaDataDeEnvio() {
    Opportunity o = classificar(novaOpp('Em Precificação'));
    System.runAs(vendedor()) {
      insert o;
      o.StageName = 'Proposta Enviada';
      update o;
    }
    Assert.areEqual(Date.today(), recarregar(o.Id).ADV_Data_Envio_Proposta__c);
  }

  @IsTest
  static void perdidoComMotivoOutrosExigeDetalhe() {
    // Perdido nao exige Area/Advogado: sai direto de Oportunidade Recebida.
    // A obrigatoriedade do motivo (VR ADV_Perdido_Exige_Motivo) esta
    // desativada de proposito pelo CLICKUP-12012 ate a lista oficial de
    // motivos; por isso nao e testada aqui.
    Opportunity o = novaOpp('Oportunidade Recebida');
    System.runAs(vendedor()) {
      insert o;
      o.StageName = 'Perdido';
      o.ADV_Motivo_Perda__c = 'Outros';
      assertBloqueado(o, 'Detalhe da perda');

      o.ADV_Detalhe_Perda__c = 'Cliente fechou com outro escritorio.';
      update o;
    }
    Opportunity salva = recarregar(o.Id);
    Assert.areEqual('Perdido', salva.StageName);
    Assert.isTrue(salva.IsClosed, 'Perdido e fechada.');
    Assert.isFalse(salva.IsWon, 'Perdido nao e ganha.');
  }

  @IsTest
  static void ganhoExigeDataAssinaturaSemMotivoDePerdaEContrato() {
    // O Flow de contrato (before-save) roda antes das VRs: sem contrato, so o
    // erro dele aparece. As VRs de Ganho sao testadas com o contrato anexado.
    Opportunity o = classificar(novaOpp('Aguardando Assinatura'));
    System.runAs(vendedor()) {
      insert o;
      o.StageName = 'Ganho';
      o.ADV_Data_Assinatura__c = Date.today();
      assertBloqueado(o, 'Anexe o contrato assinado');

      insert new ContentVersion(
        Title = 'Contrato assinado',
        PathOnClient = 'contrato.pdf',
        VersionData = Blob.valueOf('contrato'),
        FirstPublishLocationId = o.Id
      );
      o.ADV_Data_Assinatura__c = null;
      assertBloqueado(o, 'Data de assinatura');

      o.ADV_Data_Assinatura__c = Date.today();
      o.ADV_Motivo_Perda__c = 'Sem Interesse';
      assertBloqueado(o, 'limpe o motivo da perda');

      o.ADV_Motivo_Perda__c = null;
      update o;
    }
    Opportunity salva = recarregar(o.Id);
    Assert.areEqual('Ganho', salva.StageName);
    Assert.isTrue(salva.IsClosed, 'Ganho e fechada.');
    Assert.isTrue(salva.IsWon, 'Ganho e ganha.');
  }

  // ============================================================ apoio

  private static User vendedor() {
    return [SELECT Id FROM User WHERE LastName = :(PREFIXO + ' Vendedor') LIMIT 1];
  }

  private static Opportunity novaOpp(String etapa) {
    Account conta = [SELECT Id FROM Account WHERE Name = :(PREFIXO + ' Cliente') LIMIT 1];
    return new Opportunity(
      Name = PREFIXO + ' Opp ' + etapa,
      AccountId = conta.Id,
      RecordTypeId = Schema.SObjectType.Opportunity.getRecordTypeInfosByDeveloperName().get('ADV').getRecordTypeId(),
      StageName = etapa,
      CloseDate = Date.today().addDays(30)
    );
  }

  private static Opportunity classificar(Opportunity o) {
    o.ADV_Area_Juridica__c = 'Trabalhista';
    o.ADV_Advogado_Responsavel__c = 'Ana Luiza';
    return o;
  }

  private static void assertBloqueado(Opportunity o, String trechoMensagem) {
    Database.SaveResult r = Database.update(o, false);
    Assert.isFalse(r.isSuccess(), 'Deveria bloquear: ' + trechoMensagem);
    String msgs = '';
    for (Database.Error e : r.getErrors()) {
      msgs += e.getMessage() + ' | ';
    }
    Assert.isTrue(msgs.contains(trechoMensagem), 'Mensagem esperada "' + trechoMensagem + '", veio: ' + msgs);
  }

  private static Opportunity recarregar(Id oppId) {
    // SYSTEM_MODE explicito: quem roda o teste pode nao ter FLS nos campos ADV.
    return (Opportunity) Database.queryWithBinds(
      'SELECT StageName, IsClosed, IsWon, Probability, ADV_Data_Envio_Proposta__c FROM Opportunity WHERE Id = :oppId',
      new Map<String, Object>{ 'oppId' => oppId },
      AccessLevel.SYSTEM_MODE
    )[0];
  }

  private static void assertEtapa(OpportunityStage e, Boolean fechada, Boolean ganha, Integer prob, String categoria) {
    Assert.isNotNull(e, 'Etapa ausente.');
    Assert.areEqual(fechada, e.IsClosed, e.ApiName + ' IsClosed');
    Assert.areEqual(ganha, e.IsWon, e.ApiName + ' IsWon');
    Assert.areEqual(prob, e.DefaultProbability, e.ApiName + ' probabilidade');
    Assert.areEqual(categoria, e.ForecastCategoryName, e.ApiName + ' categoria de previsao');
  }
}
