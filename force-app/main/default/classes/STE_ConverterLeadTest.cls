/**
 * Cobre os três cenários de aceite da US 05 e os bloqueios que o cenário 01
 * pressupõe ("um Lead com a CNH validada").
 */
@IsTest
private class STE_ConverterLeadTest {
  private static final String CATALOGO = 'Catálogo Stech Telecom';
  private static final String CODIGO = 'STE-TEL-001';

  @TestSetup
  static void prepararCatalogo() {
    Product2 telecom = new Product2(
      Name = 'Telecom',
      ProductCode = CODIGO,
      IsActive = true
    );
    insert telecom;

    // Um produto só entra em catálogo custom depois de ter preço no padrão.
    insert new PricebookEntry(
      Pricebook2Id = Test.getStandardPricebookId(),
      Product2Id = telecom.Id,
      UnitPrice = 0,
      IsActive = true
    );

    Pricebook2 catalogo = new Pricebook2(Name = CATALOGO, IsActive = true);
    insert catalogo;

    insert new PricebookEntry(
      Pricebook2Id = catalogo.Id,
      Product2Id = telecom.Id,
      UnitPrice = 0,
      IsActive = true
    );
  }

  private static Lead novoCandidato(String sobrenome, String cpf) {
    return new Lead(
      FirstName = 'Ana',
      LastName = sobrenome,
      Company = 'Ana ' + sobrenome,
      Email = 'ana.' + sobrenome.toLowerCase() + '@exemplo.com',
      MobilePhone = '11988887777',
      Status = 'Validação',
      RecordTypeId = Lead.SObjectType.getDescribe()
        .getRecordTypeInfosByDeveloperName()
        .get('STE')
        .getRecordTypeId(),
      CPF__c = cpf,
      STE_RG__c = '12.345.678-X',
      STE_Data_Nascimento__c = Date.newInstance(1990, 5, 20),
      STE_CNH_Enviada__c = true,
      STE_Data_Envio_CNH__c = System.now(),
      STE_Genero__c = 'Feminino',
      STE_Classificacao_Fila__c = 'Quente',
      STE_Faixa_Etaria__c = 'De 20 a 50 anos',
      STE_Possui_CNH__c = 'Sim, envio imediato'
    );
  }

  @IsTest
  static void converteCandidatoCompleto() {
    Lead l = novoCandidato('Souza', '111.111.111-11');
    insert l;

    Test.startTest();
    List<STE_ConverterLead.Resultado> r = STE_ConverterLead.converter(
      new List<Id>{ l.Id }
    );
    Test.stopTest();

    Assert.areEqual(1, r.size(), 'Deveria devolver um resultado por Lead.');
    Assert.isTrue(r[0].convertido, r[0].mensagem);

    // Cenário 01 — os três registros existem e estão ligados entre si.
    Account conta = [
      SELECT Id, Name, STE_CPF__c, RecordType.DeveloperName
      FROM Account
      WHERE Id = :r[0].contaId
    ];
    Assert.areEqual(
      'STE_Pessoa_Fisica',
      conta.RecordType.DeveloperName,
      'A Conta deveria nascer com o record type de pessoa física.'
    );
    Assert.areEqual('111.111.111-11', conta.STE_CPF__c);

    Contact contato = [
      SELECT
        AccountId,
        CPF__c,
        STE_RG__c,
        Birthdate,
        STE_WhatsApp__c,
        STE_Genero__c,
        STE_Classificacao_Fila__c
      FROM Contact
      WHERE Id = :r[0].contatoId
    ];
    Assert.areEqual(
      conta.Id,
      contato.AccountId,
      'Contato deveria estar sob a Conta.'
    );
    Assert.areEqual(
      '11988887777',
      contato.STE_WhatsApp__c,
      'Regra 4.2 — WhatsApp.'
    );
    Assert.areEqual('111.111.111-11', contato.CPF__c);
    Assert.areEqual(
      '12.345.678-X',
      contato.STE_RG__c,
      'O RG do candidato deveria ter sido copiado para o Contato.'
    );
    Assert.areEqual(
      Date.newInstance(1990, 5, 20),
      contato.Birthdate,
      'A data de nascimento deveria ter sido copiada para o Contato.'
    );
    Assert.areEqual('Feminino', contato.STE_Genero__c);
    Assert.areEqual('Quente', contato.STE_Classificacao_Fila__c);

    Opportunity op = [
      SELECT
        AccountId,
        StageName,
        Pricebook2Id,
        RecordType.DeveloperName,
        STE_Faixa_Etaria__c,
        STE_Possui_CNH__c
      FROM Opportunity
      WHERE Id = :r[0].oportunidadeId
    ];
    Assert.areEqual(
      conta.Id,
      op.AccountId,
      'Oportunidade deveria estar sob a Conta.'
    );
    Assert.areEqual('STE_Telecom', op.RecordType.DeveloperName);
    Assert.areEqual(
      'Verificação de Antecedentes',
      op.StageName,
      'Visão de processo — a Oportunidade avança para a verificação.'
    );

    // Cenário 02 — faixa etária e posse de CNH transferidas do Lead.
    Assert.areEqual('De 20 a 50 anos', op.STE_Faixa_Etaria__c);
    Assert.areEqual('Sim, envio imediato', op.STE_Possui_CNH__c);

    // Cenário 03 — o catálogo da Oportunidade só oferece o Telecom.
    // O nome da variável não pode ser "catalogo": o Apex ignora
    // maiúsculas e ela colidiria com a constante CATALOGO.
    Pricebook2 catalogoDaOportunidade = [
      SELECT Id, Name
      FROM Pricebook2
      WHERE Id = :op.Pricebook2Id
    ];
    Assert.areEqual(CATALOGO, catalogoDaOportunidade.Name);
    Assert.areEqual(
      1,
      [
        SELECT COUNT()
        FROM PricebookEntry
        WHERE Pricebook2Id = :catalogoDaOportunidade.Id AND IsActive = TRUE
      ],
      'O catálogo do funil deve ter exatamente um produto disponível.'
    );

    List<OpportunityLineItem> itens = [
      SELECT Product2.ProductCode
      FROM OpportunityLineItem
      WHERE OpportunityId = :op.Id
    ];
    Assert.areEqual(
      1,
      itens.size(),
      'Regra 4.4 — o curso deveria entrar associado.'
    );
    Assert.areEqual(CODIGO, itens[0].Product2.ProductCode);
  }

  @IsTest
  static void reaproveitaContaDoMesmoCPF() {
    Account existente = new Account(
      Name = 'Ana Previa',
      STE_CPF__c = '222.222.222-22',
      RecordTypeId = Account.SObjectType.getDescribe()
        .getRecordTypeInfosByDeveloperName()
        .get('STE_Pessoa_Fisica')
        .getRecordTypeId()
    );
    insert existente;

    Lead l = novoCandidato('Previa', '222.222.222-22');
    insert l;

    Test.startTest();
    List<STE_ConverterLead.Resultado> r = STE_ConverterLead.converter(
      new List<Id>{ l.Id }
    );
    Test.stopTest();

    Assert.isTrue(r[0].convertido, r[0].mensagem);
    Assert.areEqual(
      existente.Id,
      r[0].contaId,
      'Deveria reaproveitar a Conta do CPF, não criar uma segunda.'
    );
    Assert.areEqual(
      1,
      [SELECT COUNT() FROM Account WHERE STE_CPF__c = '222.222.222-22'],
      'O CPF é unique na Conta — não pode haver duplicata.'
    );
  }

  @IsTest
  static void bloqueiaSemCNHRecebida() {
    Lead l = novoCandidato('SemCnh', '333.333.333-33');
    l.STE_CNH_Enviada__c = false;
    insert l;

    Test.startTest();
    List<STE_ConverterLead.Resultado> r = STE_ConverterLead.converter(
      new List<Id>{ l.Id }
    );
    Test.stopTest();

    Assert.isFalse(r[0].convertido, 'Sem CNH não deveria converter.');
    Assert.isTrue(
      r[0].mensagem.contains('CNH'),
      'A mensagem deveria dizer o que falta: ' + r[0].mensagem
    );
    Assert.isFalse([SELECT IsConverted FROM Lead WHERE Id = :l.Id].IsConverted);
  }

  @IsTest
  static void bloqueiaSemCPF() {
    Lead l = novoCandidato('SemCpf', null);
    insert l;

    Test.startTest();
    List<STE_ConverterLead.Resultado> r = STE_ConverterLead.converter(
      new List<Id>{ l.Id }
    );
    Test.stopTest();

    Assert.isFalse(r[0].convertido, 'Sem CPF não deveria converter.');
    Assert.isTrue(
      r[0].mensagem.contains('CPF'),
      'A mensagem deveria apontar o CPF: ' + r[0].mensagem
    );
  }

  @IsTest
  static void bloqueiaLeadJaConvertido() {
    Lead l = novoCandidato('Repetida', '444.444.444-44');
    insert l;

    STE_ConverterLead.converter(new List<Id>{ l.Id });

    Test.startTest();
    List<STE_ConverterLead.Resultado> r = STE_ConverterLead.converter(
      new List<Id>{ l.Id }
    );
    Test.stopTest();

    Assert.isFalse(r[0].convertido, 'Não deveria converter duas vezes.');
    Assert.isTrue(
      r[0].mensagem.contains('já foi convertido'),
      'Mensagem inesperada: ' + r[0].mensagem
    );
  }

  @IsTest
  static void avisaQuandoOLeadNaoExiste() {
    // Id sintético de Lead: o registro não existe, então a busca não o traz.
    Id inexistente = '00Q000000000000AAA';

    Test.startTest();
    List<STE_ConverterLead.Resultado> r = STE_ConverterLead.converter(
      new List<Id>{ inexistente }
    );
    Test.stopTest();

    Assert.isFalse(r[0].convertido);
    Assert.isTrue(r[0].mensagem.contains('não encontrado'), r[0].mensagem);
  }

  @IsTest
  static void entradaVaziaNaoQuebra() {
    Assert.areEqual(0, STE_ConverterLead.converter(new List<Id>()).size());
    Assert.areEqual(0, STE_ConverterLead.converter(null).size());
  }

  @IsTest
  static void converteCandidatoSemRG() {
    // RG é opcional: a conversão não pode ser bloqueada pela ausência dele.
    Lead l = novoCandidato('Ribeiro', '333.333.333-33');
    l.STE_RG__c = null;
    insert l;

    Test.startTest();
    List<STE_ConverterLead.Resultado> r = STE_ConverterLead.converter(
      new List<Id>{ l.Id }
    );
    Test.stopTest();

    Assert.isTrue(r[0].convertido, r[0].mensagem);

    Contact contato = [
      SELECT STE_RG__c
      FROM Contact
      WHERE Id = :r[0].contatoId
    ];
    Assert.isNull(
      contato.STE_RG__c,
      'Sem RG no Lead, o Contato deveria ficar com o campo em branco.'
    );
  }

  @IsTest
  static void converteSemDataDeNascimento() {
    // A data de nascimento é opcional: a conversão não pode depender dela.
    Lead l = novoCandidato('Moraes', '444.444.444-44');
    l.STE_Data_Nascimento__c = null;
    insert l;

    Test.startTest();
    List<STE_ConverterLead.Resultado> r = STE_ConverterLead.converter(
      new List<Id>{ l.Id }
    );
    Test.stopTest();

    Assert.isTrue(r[0].convertido, r[0].mensagem);

    Contact contato = [
      SELECT Birthdate
      FROM Contact
      WHERE Id = :r[0].contatoId
    ];
    Assert.isNull(
      contato.Birthdate,
      'Sem data no Lead, o Contato deveria ficar com o campo em branco.'
    );
  }

  @IsTest
  static void bloqueiaDataDeNascimentoFutura() {
    // Data no futuro é sempre erro de digitação, normalmente o ano trocado.
    Lead l = novoCandidato('Futuro', '555.555.555-55');
    l.STE_Data_Nascimento__c = Date.today().addDays(1);

    try {
      insert l;
      Assert.fail('Data de nascimento no futuro deveria ter sido barrada.');
    } catch (DmlException e) {
      Assert.isTrue(
        e.getMessage().contains('não pode estar no futuro'),
        'A mensagem deveria apontar a data futura: ' + e.getMessage()
      );
    }
  }

  @IsTest
  static void aceitaDataDeNascimentoDeHoje() {
    // A regra barra apenas datas estritamente futuras.
    Lead l = novoCandidato('Hoje', '666.666.666-66');
    l.STE_Data_Nascimento__c = Date.today();
    insert l;

    Assert.areEqual(
      Date.today(),
      [SELECT STE_Data_Nascimento__c FROM Lead WHERE Id = :l.Id]
        .STE_Data_Nascimento__c,
      'A data de hoje deveria ser aceita.'
    );
  }

  @IsTest
  static void aceitaCandidatoMuitoIdoso() {
    // Não existe limite de idade no cadastro: a seleção é do assistente.
    Lead l = novoCandidato('Centenaria', '777.777.777-77');
    l.STE_Data_Nascimento__c = Date.newInstance(1920, 1, 1);
    insert l;

    Assert.areEqual(
      Date.newInstance(1920, 1, 1),
      [SELECT STE_Data_Nascimento__c FROM Lead WHERE Id = :l.Id]
        .STE_Data_Nascimento__c,
      'Não deveria haver limite de idade máxima.'
    );
  }

  @IsTest
  static void dataNaoInterfereNaFaixaEtaria() {
    // A data não recalcula nem contradiz a faixa declarada no assistente.
    Lead l = novoCandidato('Incoerente', '888.888.888-88');
    l.STE_Data_Nascimento__c = Date.newInstance(2015, 1, 1);
    insert l;

    Lead salvo = [
      SELECT STE_Faixa_Etaria__c, STE_Motivo_Desqualificacao__c, Status
      FROM Lead
      WHERE Id = :l.Id
    ];
    Assert.areEqual(
      'De 20 a 50 anos',
      salvo.STE_Faixa_Etaria__c,
      'A faixa declarada no assistente não pode mudar por causa da data.'
    );
    Assert.isNull(
      salvo.STE_Motivo_Desqualificacao__c,
      'A data não pode desqualificar o candidato.'
    );

    Test.startTest();
    List<STE_ConverterLead.Resultado> r = STE_ConverterLead.converter(
      new List<Id>{ l.Id }
    );
    Test.stopTest();

    Assert.isTrue(
      r[0].convertido,
      'Data incoerente com a faixa não pode bloquear a conversão: ' +
        r[0].mensagem
    );
  }
}