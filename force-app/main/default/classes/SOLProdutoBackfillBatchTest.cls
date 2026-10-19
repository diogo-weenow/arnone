/**
 * Cobertura do backfill single -> multi de produto (Lead e Opportunity),
 * incluindo idempotência e não-sobrescrita do campo novo já preenchido.
 */
@IsTest
private class SOLProdutoBackfillBatchTest {
  private static Id rtLead() {
    return Lead.SObjectType.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get('SOL')
      .getRecordTypeId();
  }

  private static Id rtOpp() {
    return Opportunity.SObjectType.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get('SOL')
      .getRecordTypeId();
  }

  @IsTest
  static void migraLeadSingleParaMulti() {
    Lead l = new Lead(
      RecordTypeId = rtLead(),
      LastName = 'Backfill',
      Company = 'Empresa Backfill',
      Status = 'Recebido - MQL',
      Unidade_Origem__c = 'SOL',
      CNPJ__c = '11.222.333/0001-81',
      SOL_Produto_Interesse__c = 'ART 360'
    );
    insert l;
    // Garante o novo vazio no ponto de partida.
    update new Lead(Id = l.Id, SOL_Produtos_Interesse__c = null);

    Test.startTest();
    Database.executeBatch(new SOLProdutoBackfillBatch('Lead'), 200);
    Test.stopTest();

    Lead depois = [
      SELECT SOL_Produto_Interesse__c, SOL_Produtos_Interesse__c
      FROM Lead
      WHERE Id = :l.Id
    ];
    Assert.areEqual(
      'ART 360',
      depois.SOL_Produtos_Interesse__c,
      'O valor single foi copiado para o multi.'
    );
    Assert.areEqual(
      'ART 360',
      depois.SOL_Produto_Interesse__c,
      'O campo antigo permanece intacto (não é apagado).'
    );
  }

  @IsTest
  static void migraOpportunitySingleParaMulti() {
    Account a = new Account(Name = 'Conta Backfill');
    insert a;
    Opportunity o = new Opportunity(
      RecordTypeId = rtOpp(),
      Name = 'Opp Backfill',
      AccountId = a.Id,
      StageName = 'Oportunidade Criada',
      CloseDate = Date.today().addDays(30),
      SOL_Produto_Negocio__c = 'Recuperação Tributária'
    );
    insert o;
    update new Opportunity(Id = o.Id, SOL_Produtos_Negocio__c = null);

    Test.startTest();
    Database.executeBatch(new SOLProdutoBackfillBatch('Opportunity'), 200);
    Test.stopTest();

    Opportunity depois = [
      SELECT SOL_Produtos_Negocio__c
      FROM Opportunity
      WHERE Id = :o.Id
    ];
    Assert.areEqual(
      'Recuperação Tributária',
      depois.SOL_Produtos_Negocio__c,
      'O valor single foi copiado para o multi na Oportunidade.'
    );
  }

  @IsTest
  static void idempotenteNaoSobrescreveNovoJaPreenchido() {
    Lead l = new Lead(
      RecordTypeId = rtLead(),
      LastName = 'Idem',
      Company = 'Empresa Idem',
      Status = 'Recebido - MQL',
      Unidade_Origem__c = 'SOL',
      CNPJ__c = '11.222.333/0002-81',
      SOL_Produto_Interesse__c = 'ART 360',
      // Novo já tem seleção MÚLTIPLA, feita após eventual migração anterior.
      SOL_Produtos_Interesse__c = 'ART 360;Revisão trabalhista'
    );
    insert l;

    Test.startTest();
    // Reexecução do backfill não deve tocar quem já tem o novo preenchido.
    Database.executeBatch(new SOLProdutoBackfillBatch('Lead'), 200);
    Test.stopTest();

    Lead depois = [
      SELECT SOL_Produtos_Interesse__c FROM Lead WHERE Id = :l.Id
    ];
    Assert.areEqual(
      'ART 360;Revisão trabalhista',
      depois.SOL_Produtos_Interesse__c,
      'Backfill é idempotente: não sobrescreve seleção múltipla existente.'
    );
  }

  /** Opp ART fechada como Perdido, com o produto só no campo antigo. */
  private static Id oppFechadaSoNoCampoAntigo() {
    Account a = new Account(Name = 'Conta Terminal');
    insert a;
    Opportunity o = new Opportunity(
      RecordTypeId = rtOpp(),
      Name = 'Opp Terminal',
      AccountId = a.Id,
      StageName = 'Negociação',
      CloseDate = Date.today().addDays(30),
      SOL_Produto_Negocio__c = 'ART 360'
    );
    insert o;
    update new Opportunity(
      Id = o.Id,
      StageName = 'Perdido',
      SOL_Motivo_Perda__c = 'Sem retorno',
      SOL_Produtos_Negocio__c = null
    );
    return o.Id;
  }

  @IsTest
  static void modoAtivosIgnoraOppFechada() {
    Id oppId = oppFechadaSoNoCampoAntigo();

    Test.startTest();
    Database.executeBatch(new SOLProdutoBackfillBatch('Opportunity'), 200);
    Test.stopTest();

    Opportunity depois = [
      SELECT IsClosed, SOL_Produtos_Negocio__c FROM Opportunity WHERE Id = :oppId
    ];
    Assert.isTrue(depois.IsClosed, 'Pré-condição: Opp terminal.');
    Assert.isNull(
      depois.SOL_Produtos_Negocio__c,
      'Modo padrão (ativos) NÃO toca registro terminal.'
    );
  }

  /**
   * Seleção do modo TERMINAIS. A atualização em si NÃO é exercitada aqui: em
   * teste os flows terminais estão ativos e re-disparam (a "etapa anterior"
   * seria "Perdido" e o serviço de perda recusa) — é justamente por isso que o
   * runbook roda este modo com esses flows DESATIVADOS. A migração real é
   * validada na org com antes/depois de contadores e eventos.
   */
  @IsTest
  static void modoTerminaisSelecionaSoOppFechada() {
    Id oppFechada = oppFechadaSoNoCampoAntigo();
    Account a = [SELECT Id FROM Account WHERE Name = 'Conta Terminal' LIMIT 1];
    Opportunity aberta = new Opportunity(
      RecordTypeId = rtOpp(),
      Name = 'Opp Aberta',
      AccountId = a.Id,
      StageName = 'Oportunidade Criada',
      CloseDate = Date.today().addDays(30),
      SOL_Produto_Negocio__c = 'ART 360'
    );
    insert aberta;

    Set<Id> terminais = idsDoStart(new SOLProdutoBackfillBatch('Opportunity', true));
    Set<Id> ativos = idsDoStart(new SOLProdutoBackfillBatch('Opportunity'));

    Assert.isTrue(terminais.contains(oppFechada), 'Terminais inclui a Opp fechada.');
    Assert.isFalse(terminais.contains(aberta.Id), 'Terminais exclui a Opp aberta.');
    Assert.isTrue(ativos.contains(aberta.Id), 'Ativos inclui a Opp aberta.');
    Assert.isFalse(ativos.contains(oppFechada), 'Ativos exclui a Opp fechada.');
  }

  private static Set<Id> idsDoStart(SOLProdutoBackfillBatch b) {
    Set<Id> ids = new Set<Id>();
    Database.QueryLocatorIterator it = b.start(null).iterator();
    while (it.hasNext()) {
      ids.add(it.next().Id);
    }
    return ids;
  }

  @IsTest
  static void objetoNaoSuportadoFalha() {
    Boolean falhou = false;
    try {
      new SOLProdutoBackfillBatch('Contact');
    } catch (SOLProdutoBackfillBatch.BackfillException e) {
      falhou = true;
    }
    Assert.isTrue(falhou, 'Objeto fora de Lead/Opportunity é rejeitado.');
  }
}
