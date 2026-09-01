/**
 * Testes do CLICKUP-9350. Cobrem o PASSO 3 do card: Recuperação Tributária com
 * e sem procuração, ART 360 com e sem liberação, Conta nova e reaproveitada,
 * CNPJ ausente, arquivo, usuário sem permissão e ausência de efeito sobre lead
 * fora da unidade.
 */
@IsTest
private class SOL_ConverterLeadTest {
  private static final String CNPJ_MASCARADO = '11.222.333/0001-81';
  private static final String CNPJ_CRU = '11222333000181';

  private static Id rtLead() {
    return Lead.SObjectType.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get('SOL')
      .getRecordTypeId();
  }

  private static Lead novoLead(String produto, String cnpj) {
    Lead l = new Lead(
      RecordTypeId = rtLead(),
      FirstName = 'Marina',
      LastName = 'Teste',
      Company = 'Industria Teste LTDA',
      Email = 'marina.teste@exemplo.com',
      Status = 'Apto para Conversão',
      Unidade_Origem__c = 'SOL',
      CNPJ__c = cnpj,
      SOL_Produto_Interesse__c = produto
    );
    // As regras de duplicidade da org só alertam na interface, mas em Apex o
    // alerta vira exceção. Nos cenários de reaproveitamento existe de propósito
    // uma Conta/Contato parecidos, e é isso que o teste quer exercitar.
    Database.DMLOptions opcoes = new Database.DMLOptions();
    opcoes.duplicateRuleHeader.allowSave = true;
    Database.insert(l, opcoes);
    return l;
  }

  /** Procuração recebida com documento anexado, como o card exige. */
  private static Lead leadComProcuracao() {
    Lead l = novoLead('Recuperação Tributária', CNPJ_MASCARADO);
    l.SOL_Status_Procuracao__c = 'Recebida';
    l.SOL_Data_Recebimento_Procuracao__c = Date.today();
    update l;
    anexar(l.Id);
    return l;
  }

  private static Id anexar(Id registroId) {
    ContentVersion cv = new ContentVersion(
      Title = 'Procuracao assinada',
      PathOnClient = 'procuracao.txt',
      VersionData = Blob.valueOf('documento')
    );
    insert cv;
    Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id]
    .ContentDocumentId;
    insert new ContentDocumentLink(
      ContentDocumentId = docId,
      LinkedEntityId = registroId,
      ShareType = 'V'
    );
    return docId;
  }

  private static SOL_ConverterLead.Pedido pedidoDe(Id leadId, Id contaId) {
    SOL_ConverterLead.Pedido p = new SOL_ConverterLead.Pedido();
    p.leadId = leadId;
    p.contaId = contaId;
    return p;
  }

  // ------------------------------------------------------------------ portões

  @IsTest
  static void naoConverteRecuperacaoSemProcuracao() {
    Lead l = novoLead('Recuperação Tributária', CNPJ_MASCARADO);

    Test.startTest();
    SOL_PrepararConversao.Preparo p = SOL_PrepararConversao.preparar(
      new List<Id>{ l.Id }
    )[0];
    SOL_ConverterLead.Resultado r = SOL_ConverterLead.converter(
      new List<SOL_ConverterLead.Pedido>{ pedidoDe(l.Id, null) }
    )[0];
    Test.stopTest();

    Assert.isFalse(p.podeConverter, 'Sem procuração não deveria liberar.');
    Assert.isTrue(
      p.impedimento.contains('procuração ainda não foi recebida'),
      'A mensagem deveria explicar o portão: ' + p.impedimento
    );
    Assert.isFalse(r.convertido, 'A classe não pode converter sem procuração.');
    Assert.isFalse(
      [SELECT IsConverted FROM Lead WHERE Id = :l.Id].IsConverted,
      'O lead continua lead.'
    );
  }

  @IsTest
  static void naoConverteRecuperacaoSemArquivo() {
    Lead l = novoLead('Recuperação Tributária', CNPJ_MASCARADO);
    l.SOL_Status_Procuracao__c = 'Recebida';
    update l;

    Test.startTest();
    SOL_PrepararConversao.Preparo p = SOL_PrepararConversao.preparar(
      new List<Id>{ l.Id }
    )[0];
    Test.stopTest();

    Assert.isFalse(p.podeConverter, 'Recebida sem arquivo não é recebida.');
    Assert.isTrue(
      p.impedimento.contains('não há arquivo anexado'),
      'Mensagem inesperada: ' + p.impedimento
    );
  }

  @IsTest
  static void naoConverteSemCnpj() {
    Lead l = novoLead('Recuperação Tributária', null);
    l.SOL_Status_Procuracao__c = 'Recebida';
    update l;
    anexar(l.Id);

    Test.startTest();
    SOL_PrepararConversao.Preparo p = SOL_PrepararConversao.preparar(
      new List<Id>{ l.Id }
    )[0];
    Test.stopTest();

    Assert.isTrue(
      p.impedimento.contains('CNPJ'),
      'Sem CNPJ não há como evitar duplicata: ' + p.impedimento
    );
  }

  @IsTest
  static void naoConverteLeadDeOutraUnidade() {
    Lead l = new Lead(
      FirstName = 'Fora',
      LastName = 'Da Unidade',
      Company = 'Outra Empresa',
      Status = 'Novo',
      CNPJ__c = CNPJ_MASCARADO
    );
    insert l;

    Test.startTest();
    SOL_ConverterLead.Resultado r = SOL_ConverterLead.converter(
      new List<SOL_ConverterLead.Pedido>{ pedidoDe(l.Id, null) }
    )[0];
    Test.stopTest();

    Assert.isFalse(r.convertido, 'Lead Master não pode ser tocado por aqui.');
    Assert.isTrue(
      r.mensagem.contains('não é da Arnone Soluções'),
      'Mensagem inesperada: ' + r.mensagem
    );
    Assert.isFalse(
      [SELECT IsConverted FROM Lead WHERE Id = :l.Id].IsConverted,
      'O lead de fora da unidade continua intacto.'
    );
  }

  @IsTest
  static void naoConverteDuasVezes() {
    Lead l = leadComProcuracao();

    Test.startTest();
    SOL_ConverterLead.converter(
      new List<SOL_ConverterLead.Pedido>{ pedidoDe(l.Id, null) }
    );
    SOL_ConverterLead.Resultado segunda = SOL_ConverterLead.converter(
      new List<SOL_ConverterLead.Pedido>{ pedidoDe(l.Id, null) }
    )[0];
    Test.stopTest();

    Assert.isFalse(segunda.convertido, 'Conversão não se repete.');
    Assert.isTrue(
      segunda.mensagem.contains('já foi convertido'),
      'Mensagem inesperada: ' + segunda.mensagem
    );
  }

  // --------------------------------------------------------------- conversão

  @IsTest
  static void converteRecuperacaoCriandoContaNova() {
    Lead l = leadComProcuracao();

    Test.startTest();
    SOL_ConverterLead.Resultado r = SOL_ConverterLead.converter(
      new List<SOL_ConverterLead.Pedido>{ pedidoDe(l.Id, null) }
    )[0];
    Test.stopTest();

    Assert.isTrue(r.convertido, 'Deveria converter: ' + r.mensagem);

    Account a = [
      SELECT Name, CNPJ__c, Unidades_Atendidas__c
      FROM Account
      WHERE Id = :r.contaId
    ];
    Assert.areEqual('Industria Teste LTDA', a.Name, 'Conta pela empresa.');
    Assert.areEqual(
      CNPJ_MASCARADO,
      a.CNPJ__c,
      'O CNPJ precisa chegar à conta.'
    );
    Assert.areEqual('SOL', a.Unidades_Atendidas__c, 'A unidade fica marcada.');

    Contact c = [SELECT AccountId FROM Contact WHERE Id = :r.contatoId];
    Assert.areEqual(a.Id, c.AccountId, 'Contato ligado à conta.');

    Opportunity o = [
      SELECT
        StageName,
        RecordType.DeveloperName,
        AccountId,
        SOL_Produto_Negocio__c
      FROM Opportunity
      WHERE Id = :r.oportunidadeId
    ];
    Assert.areEqual(
      'SOL',
      o.RecordType.DeveloperName,
      'Precisa entrar no funil da BU.'
    );
    Assert.areEqual(
      'Diagnóstico',
      o.StageName,
      'Recuperação Tributária vai ao Diagnóstico.'
    );
    Assert.areEqual(
      'Recuperação Tributária',
      o.SOL_Produto_Negocio__c,
      'O produto de interesse vira produto de negócio.'
    );
    Assert.areEqual(a.Id, o.AccountId, 'Oportunidade ligada à conta.');

    Assert.isTrue(
      [SELECT IsConverted FROM Lead WHERE Id = :l.Id].IsConverted,
      'O lead precisa ficar convertido.'
    );
  }

  /**
   * O arquivo da procuração precisa terminar visível na Oportunidade. Quem faz
   * isso é a própria plataforma, não a classe — o teste existe para avisar caso
   * esse comportamento mude numa release.
   */
  @IsTest
  static void arquivoDaProcuracaoSegueParaAOportunidade() {
    Lead l = leadComProcuracao();

    Test.startTest();
    SOL_ConverterLead.Resultado r = SOL_ConverterLead.converter(
      new List<SOL_ConverterLead.Pedido>{ pedidoDe(l.Id, null) }
    )[0];
    Test.stopTest();

    List<ContentDocumentLink> naOportunidade = [
      SELECT Id
      FROM ContentDocumentLink
      WHERE LinkedEntityId = :r.oportunidadeId
    ];
    Assert.isFalse(
      naOportunidade.isEmpty(),
      'A procuração deveria estar visível na Oportunidade.'
    );
  }

  @IsTest
  static void reaproveitaContaQuandoOCnpjJaExiste() {
    // Mesmo CNPJ, grafia diferente e razão social diferente: é o caso que as
    // regras de duplicidade padrão não pegam, porque elas casam por nome.
    Account existente = new Account(
      Name = 'Industria Teste Brasileira SA',
      CNPJ__c = CNPJ_CRU,
      Unidades_Atendidas__c = 'ADV'
    );
    insert existente;

    Lead l = leadComProcuracao();

    Test.startTest();
    SOL_PrepararConversao.Preparo p = SOL_PrepararConversao.preparar(
      new List<Id>{ l.Id }
    )[0];
    SOL_ConverterLead.Resultado r = SOL_ConverterLead.converter(
      new List<SOL_ConverterLead.Pedido>{
        pedidoDe(l.Id, (Id) p.contaSugeridaId)
      }
    )[0];
    Test.stopTest();

    Assert.areEqual(
      existente.Id,
      (Id) p.contaSugeridaId,
      'A busca por CNPJ normalizado deveria achar a conta.'
    );
    Assert.isTrue(r.convertido, 'Deveria converter: ' + r.mensagem);
    Assert.areEqual(existente.Id, (Id) r.contaId, 'Nenhuma conta nova.');

    Account a = [
      SELECT Name, CNPJ__c, Unidades_Atendidas__c
      FROM Account
      WHERE Id = :existente.Id
    ];
    Assert.areEqual(
      'Industria Teste Brasileira SA',
      a.Name,
      'O nome da conta existente não pode ser sobrescrito.'
    );
    Assert.areEqual(
      CNPJ_CRU,
      a.CNPJ__c,
      'O CNPJ já preenchido fica como está.'
    );
    Assert.isTrue(
      a.Unidades_Atendidas__c.contains('ADV') &&
      a.Unidades_Atendidas__c.contains('SOL'),
      'A unidade é acrescentada, não trocada: ' + a.Unidades_Atendidas__c
    );
  }

  /**
   * A conta reaproveitada já tem a pessoa cadastrada e o usuário insiste em
   * criar outra: a plataforma barra, e a mensagem precisa dizer o que fazer em
   * vez de repassar o erro cru. É o "evitar merge silencioso" do card.
   */
  @IsTest
  static void avisaQuandoOContatoJaExisteNaConta() {
    Account existente = new Account(Name = 'Empresa Y', CNPJ__c = CNPJ_CRU);
    insert existente;
    insert new Contact(
      LastName = 'Teste',
      FirstName = 'Marina',
      Email = 'marina.teste@exemplo.com',
      AccountId = existente.Id
    );

    Lead l = leadComProcuracao();

    Test.startTest();
    SOL_PrepararConversao.Preparo preparo = SOL_PrepararConversao.preparar(
      new List<Id>{ l.Id }
    )[0];
    // De propósito sem informar o contato: é o usuário ignorando a sugestão.
    SOL_ConverterLead.Resultado r = SOL_ConverterLead.converter(
      new List<SOL_ConverterLead.Pedido>{ pedidoDe(l.Id, existente.Id) }
    )[0];
    Test.stopTest();

    Assert.isNotNull(
      preparo.contatoSugeridoId,
      'A tela deveria ter oferecido o contato existente.'
    );
    Assert.isFalse(r.convertido, 'Não pode criar contato duplicado.');
    Assert.isTrue(
      r.mensagem.contains('escolha o contato existente'),
      'A mensagem precisa dizer o caminho: ' + r.mensagem
    );
    Assert.isFalse(
      [SELECT IsConverted FROM Lead WHERE Id = :l.Id].IsConverted,
      'Nada pode ter sido gravado pela metade.'
    );
  }

  @IsTest
  static void reaproveitaContatoEscolhido() {
    Account existente = new Account(Name = 'Empresa X', CNPJ__c = CNPJ_CRU);
    insert existente;
    Contact antigo = new Contact(
      LastName = 'Teste',
      FirstName = 'Marina',
      Email = 'marina.teste@exemplo.com',
      AccountId = existente.Id
    );
    insert antigo;

    Lead l = leadComProcuracao();
    SOL_ConverterLead.Pedido p = pedidoDe(l.Id, existente.Id);
    p.contatoId = antigo.Id;

    Test.startTest();
    SOL_ConverterLead.Resultado r = SOL_ConverterLead.converter(
      new List<SOL_ConverterLead.Pedido>{ p }
    )[0];
    Test.stopTest();

    Assert.isTrue(r.convertido, 'Deveria converter: ' + r.mensagem);
    Assert.areEqual(
      antigo.Id,
      (Id) r.contatoId,
      'O contato escolhido deveria ser reaproveitado.'
    );
    Assert.areEqual(
      1,
      [SELECT COUNT() FROM Contact WHERE AccountId = :existente.Id],
      'Nenhum contato duplicado.'
    );
  }

  // ------------------------------------------------------------------ ART 360

  @IsTest
  static void artTambemExigeProcuracao() {
    // Até 25/08/2026 ART 360 dispensava a procuração e entrava pelo checkbox
    // do atendente. Agora o portão é o mesmo para todos os produtos.
    Lead l = novoLead('ART 360', CNPJ_MASCARADO);
    l.SOL_Apto_Conversao__c = true;
    update l;

    Test.startTest();
    SOL_PrepararConversao.Preparo p = SOL_PrepararConversao.preparar(
      new List<Id>{ l.Id }
    )[0];
    SOL_ConverterLead.Resultado r = SOL_ConverterLead.converter(
      new List<SOL_ConverterLead.Pedido>{ pedidoDe(l.Id, null) }
    )[0];
    Test.stopTest();

    Assert.isFalse(p.podeConverter, 'Sem procuração, ART também é barrado.');
    Assert.isTrue(
      p.impedimento.contains('procuração ainda não foi recebida'),
      'Mensagem inesperada: ' + p.impedimento
    );
    Assert.isFalse(
      r.convertido,
      'O checkbox antigo não pode mais servir de porta de entrada.'
    );
  }

  @IsTest
  static void converteArtComProcuracaoDiretoParaNegociacao() {
    // Com a procuração recebida, ART converte — e continua pulando o
    // Diagnóstico e-CAC, que é decisão de etapa e não de documento.
    Lead l = novoLead('ART 360', CNPJ_MASCARADO);
    l.SOL_Status_Procuracao__c = 'Recebida';
    l.SOL_Data_Recebimento_Procuracao__c = Date.today();
    update l;
    anexar(l.Id);

    Test.startTest();
    SOL_PrepararConversao.Preparo p = SOL_PrepararConversao.preparar(
      new List<Id>{ l.Id }
    )[0];
    SOL_ConverterLead.Resultado r = SOL_ConverterLead.converter(
      new List<SOL_ConverterLead.Pedido>{ pedidoDe(l.Id, null) }
    )[0];
    Test.stopTest();

    Assert.isTrue(p.podeConverter, 'Com procuração, pode converter.');
    Assert.isTrue(r.convertido, 'Deveria converter: ' + r.mensagem);

    Opportunity o = [
      SELECT StageName, SOL_Produto_Negocio__c
      FROM Opportunity
      WHERE Id = :r.oportunidadeId
    ];
    Assert.areEqual(
      'Negociação',
      o.StageName,
      'ART 360 não tem diagnóstico e-CAC: vai direto para a Negociação.'
    );
    Assert.areEqual('ART 360', o.SOL_Produto_Negocio__c, 'Produto mapeado.');
  }

  // ------------------------------------------------------------- permissões

  /**
   * Quem não enxerga o lead recebe uma recusa explicada, não uma exceção. A
   * classe é "with sharing": para o usuário sem acesso o registro simplesmente
   * não existe.
   */
  @IsTest
  static void usuarioSemAcessoNaoConverte() {
    Lead l = leadComProcuracao();
    User semAcesso = usuarioSemAcesso();

    Test.startTest();
    System.runAs(semAcesso) {
      SOL_ConverterLead.Resultado r = SOL_ConverterLead.converter(
        new List<SOL_ConverterLead.Pedido>{ pedidoDe(l.Id, null) }
      )[0];
      Assert.isFalse(r.convertido, 'Sem acesso não converte.');
      Assert.isTrue(
        r.mensagem.contains('conjunto de permissões'),
        'Mensagem inesperada: ' + r.mensagem
      );
    }
    Test.stopTest();

    Assert.isFalse(
      [SELECT IsConverted FROM Lead WHERE Id = :l.Id].IsConverted,
      'O lead continua lead.'
    );
  }

  private static User usuarioSemAcesso() {
    Profile p = [
      SELECT Id
      FROM Profile
      WHERE UserType = 'Standard' AND PermissionsModifyAllData = FALSE
      LIMIT 1
    ];
    User u = new User(
      ProfileId = p.Id,
      LastName = 'Sem Acesso',
      Alias = 'semacc',
      Email = 'sem.acesso@exemplo.com',
      Username = 'sem.acesso.' +
        DateTime.now().getTime() +
        '@exemplo.com.teste',
      TimeZoneSidKey = 'America/Sao_Paulo',
      LocaleSidKey = 'pt_BR',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'pt_BR'
    );
    // Usuário é setup object: criar fora de um runAs misturaria DML de setup e
    // de dados na mesma transação.
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert u;
    }
    return u;
  }

  // ------------------------------------------------------------- normalização

  @IsTest
  static void variantesCobremAsDuasGrafias() {
    Set<String> v = SOL_ConverterLead.variantesDe('11222333000181');
    Assert.isTrue(v.contains(CNPJ_CRU), 'Deveria conter só os dígitos.');
    Assert.isTrue(
      v.contains(CNPJ_MASCARADO),
      'Deveria conter a forma pontuada.'
    );
    Assert.isTrue(
      SOL_ConverterLead.variantesDe(null).isEmpty(),
      'Sem CNPJ não há o que procurar.'
    );
  }
}