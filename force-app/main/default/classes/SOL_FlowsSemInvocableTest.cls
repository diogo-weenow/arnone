/**
 * Cobertura dos flows que NÃO chamam Apex invocable.
 *
 * Os testes existentes exercitam os flows por meio das classes invocable que
 * eles acionam — o que deixa de fora os flows puros, que resolvem tudo em
 * fórmula e atribuição. Isso mantinha a cobertura de processos e flows
 * autolaunched em 68%, abaixo dos 75% que a Salesforce exige para deploy em
 * produção.
 *
 * As asserções são de comportamento: cada teste verifica o que o flow grava,
 * não a sua execução.
 */
@IsTest
private class SOL_FlowsSemInvocableTest {
  private static final String PRODUTO = 'Recuperação Tributária';
  private static final String CNPJ = '11.222.333/0001-81';
  private static Integer seq = 0;

  private static String rnd() {
    seq++;
    return seq + 'x' + String.valueOf(Math.abs(Crypto.getRandomInteger()));
  }

  private static Id rtOppSOL() {
    return Opportunity.SObjectType.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get('SOL')
      .getRecordTypeId();
  }

  /**
   * Opp SOL / Recuperação Tributária com os requisitos de e-CAC e de Ganho já
   * satisfeitos, para poder avançar até a etapa pedida.
   */
  private static Opportunity novaOpp() {
    Account a = new Account(Name = 'Conta ' + rnd());
    insert a;
    Opportunity o = new Opportunity(
      Name = 'Op ' + rnd(),
      AccountId = a.Id,
      RecordTypeId = rtOppSOL(),
      CloseDate = Date.today().addDays(60),
      StageName = 'Diagnóstico',
      SOL_Produto_Negocio__c = PRODUTO,
      SOL_ECAC_Consulta_Realizada__c = true,
      SOL_ECAC_Data_Consulta__c = Date.today(),
      SOL_ECAC_Resultado__c = 'Valor a recuperar',
      SOL_Valor_Recuperavel__c = 1000,
      SOL_Apresentacao_Realizada__c = true,
      SOL_Data_Apresentacao__c = Date.today(),
      SOL_Resultado_Apresentacao__c = 'Sucesso',
      SOL_Percentual_Comissao__c = 20,
      SOL_Valor_Servico__c = 5000
    );
    insert o;
    return o;
  }

  /**
   * Lead_AfterCreate_DefinirUnidade — o formulário Web-to-Lead informa só a
   * unidade de destino (A2.7); o record type é derivado dela pelo flow, porque
   * a plataforma não persiste RecordTypeId vindo do formulário.
   */
  @IsTest
  static void webToLeadSemRecordTypeRecebeORecordTypeDaUnidade() {
    Lead l = new Lead(
      LastName = 'Captacao ' + rnd(),
      Company = 'Empresa ' + rnd(),
      CNPJ__c = CNPJ,
      Unidade_Origem__c = 'SOL'
    );

    Test.startTest();
    insert l;
    Test.stopTest();

    Lead gravado = [
      SELECT RecordTypeId, RecordType.DeveloperName
      FROM Lead
      WHERE Id = :l.Id
    ];
    Assert.areEqual(
      'SOL',
      gravado.RecordType.DeveloperName,
      'O record type do Lead deve ser derivado da Unidade de Origem.'
    );
  }

  /**
   * Lead_AfterCreate_DefinirUnidade — o guardrail é só para lead criado SEM
   * record type: quando o formulário já manda um, o flow não sobrescreve.
   */
  @IsTest
  static void leadQueJaChegaComRecordTypeNaoEhSobrescrito() {
    Id rtSte = Lead.SObjectType.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get('STE')
      .getRecordTypeId();
    Lead l = new Lead(
      LastName = 'Captacao ' + rnd(),
      Company = 'Empresa ' + rnd(),
      CNPJ__c = CNPJ,
      Unidade_Origem__c = 'SOL',
      RecordTypeId = rtSte
    );

    Test.startTest();
    insert l;
    Test.stopTest();

    Lead gravado = [SELECT RecordType.DeveloperName FROM Lead WHERE Id = :l.Id];
    Assert.areEqual(
      'STE',
      gravado.RecordType.DeveloperName,
      'Record type informado na criação prevalece sobre a Unidade de Origem.'
    );
  }

  /**
   * SOL_Marco_Encerramento_Oportunidade — before-save: ao entrar em Ganho ou
   * Perdido, grava a data de encerramento na própria transação.
   */
  @IsTest
  static void ganhoGravaADataDeEncerramento() {
    Opportunity o = novaOpp();
    Assert.isNull(
      [SELECT SOL_Data_Encerramento__c FROM Opportunity WHERE Id = :o.Id]
        .SOL_Data_Encerramento__c,
      'Pré-condição: a oportunidade nasce sem data de encerramento.'
    );

    Test.startTest();
    update new Opportunity(Id = o.Id, StageName = 'Negociação');
    update new Opportunity(Id = o.Id, StageName = 'Ganho');
    Test.stopTest();

    Assert.isNotNull(
      [SELECT SOL_Data_Encerramento__c FROM Opportunity WHERE Id = :o.Id]
        .SOL_Data_Encerramento__c,
      'Entrar em Ganho deve gravar a data de encerramento.'
    );
  }

  /**
   * SOL_Negociacao_Valor — before-save: o Amount da oportunidade passa a
   * espelhar o total da Arnone, recalculado a partir dos campos crus (o campo
   * de fórmula não está disponível antes da gravação).
   */
  @IsTest
  static void amountEspelhaOTotalDaArnone() {
    Test.startTest();
    Opportunity o = novaOpp();
    Test.stopTest();

    Opportunity gravado = [
      SELECT Amount, SOL_Valor_Total_Arnone__c
      FROM Opportunity
      WHERE Id = :o.Id
    ];
    Assert.isNotNull(
      gravado.SOL_Valor_Total_Arnone__c,
      'Pré-condição: comissão e valor de serviço informados geram total.'
    );
    Assert.areEqual(
      gravado.SOL_Valor_Total_Arnone__c,
      gravado.Amount,
      'O Amount deve espelhar o total da Arnone.'
    );
  }

  /**
   * SOL_Marco_Perda_Oportunidade — before-save: ao entrar em Perdido, incrementa
   * o contador de perdas da oportunidade.
   */
  @IsTest
  static void perdidoIncrementaOContadorDePerdas() {
    Opportunity o = novaOpp();

    Test.startTest();
    update new Opportunity(Id = o.Id, StageName = 'Negociação');
    // A validação exige o motivo antes de fechar como Perdido — é ele que
    // explica o número no relatório de funil.
    update new Opportunity(
      Id = o.Id,
      StageName = 'Perdido',
      SOL_Motivo_Perda__c = 'Não houve acordo na negociação'
    );
    Test.stopTest();

    Assert.isNotNull(
      [SELECT SOL_Qtd_Perdas__c FROM Opportunity WHERE Id = :o.Id]
        .SOL_Qtd_Perdas__c,
      'Entrar em Perdido deve registrar a perda.'
    );
  }

  /**
   * STE_Antecedentes_Transicao — before-save na jornada STech Telecom: com o
   * resultado dos antecedentes preenchido, a etapa avança sozinha a partir de
   * "Verificação de Antecedentes".
   */
  @IsTest
  static void antecedentesAprovadosAvancamAEtapa() {
    Id rtSteTelecom = Opportunity.SObjectType.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get('STE_Telecom')
      .getRecordTypeId();
    Account a = new Account(Name = 'Conta ' + rnd());
    insert a;
    Opportunity o = new Opportunity(
      Name = 'Op STE ' + rnd(),
      AccountId = a.Id,
      RecordTypeId = rtSteTelecom,
      CloseDate = Date.today().addDays(30),
      StageName = 'Verificação de Antecedentes'
    );
    insert o;

    Test.startTest();
    update new Opportunity(
      Id = o.Id,
      STE_Resultado_Antecedentes__c = 'Aprovado'
    );
    String aposAntecedentes = [
      SELECT StageName
      FROM Opportunity
      WHERE Id = :o.Id
    ]
    .StageName;
    // A jornada segue sozinha: com o exame de saúde respondido, a etapa avança
    // de novo — é o STE_Saude_Avaliacao_Transicao assumindo a partir daqui.
    update new Opportunity(
      Id = o.Id,
      STE_Resultado_Exame_Saude__c = 'Aprovado'
    );
    Test.stopTest();

    Assert.areNotEqual(
      'Verificação de Antecedentes',
      aposAntecedentes,
      'Antecedentes aprovados devem tirar a oportunidade da verificação.'
    );
    Assert.areNotEqual(
      aposAntecedentes,
      [SELECT StageName FROM Opportunity WHERE Id = :o.Id].StageName,
      'Exame de saúde aprovado deve avançar a etapa outra vez.'
    );
  }
}
