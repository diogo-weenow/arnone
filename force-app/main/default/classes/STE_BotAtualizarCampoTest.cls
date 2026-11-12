@IsTest
private class STE_BotAtualizarCampoTest {
  private static Lead novoLead() {
    Lead l = new Lead(
      LastName = 'testes atualizar campo',
      Company = 'testes atualizar campo',
      Email = 'testes.atualizar@example.invalid',
      MobilePhone = '+5511988880001',
      STE_Genero__c = 'Masculino',
      STE_Telefone_E164__c = '5511988880001'
    );
    insert l;
    return l;
  }

  private static STE_BotAtualizarCampo.Resultado atualizar(
    String recordId,
    String campo,
    String valor
  ) {
    STE_BotAtualizarCampo.Entrada e = new STE_BotAtualizarCampo.Entrada();
    e.recordId = recordId;
    e.campo = campo;
    e.valor = valor;
    return STE_BotAtualizarCampo.atualizar(
      new List<STE_BotAtualizarCampo.Entrada>{ e }
    )[0];
  }

  @IsTest
  static void corrigeNomeInteiroNoSobrenome() {
    Lead l = novoLead();

    Test.startTest();
    STE_BotAtualizarCampo.Resultado r = atualizar(
      l.Id,
      'Nome',
      '  testes nome corrigido  '
    );
    Test.stopTest();

    Assert.isTrue(r.sucesso, r.mensagem);
    Lead depois = [
      SELECT Name, FirstName, LastName
      FROM Lead
      WHERE Id = :l.Id
    ];
    Assert.areEqual('testes nome corrigido', depois.LastName);
    Assert.areEqual(null, depois.FirstName, 'FirstName deveria ficar limpo');
    Assert.areEqual('testes nome corrigido', depois.Name);
  }

  @IsTest
  static void corrigeEmailEGenero() {
    Lead l = novoLead();

    Test.startTest();
    STE_BotAtualizarCampo.Resultado email = atualizar(
      l.Id,
      'E-mail',
      'testes.novo@example.invalid'
    );
    STE_BotAtualizarCampo.Resultado genero = atualizar(
      l.Id,
      'Gênero',
      'feminino'
    );
    Test.stopTest();

    Assert.isTrue(email.sucesso, email.mensagem);
    Assert.isTrue(genero.sucesso, genero.mensagem);
    Lead depois = [
      SELECT Email, STE_Genero__c
      FROM Lead
      WHERE Id = :l.Id
    ];
    Assert.areEqual('testes.novo@example.invalid', depois.Email);
    Assert.areEqual('Feminino', depois.STE_Genero__c, 'aceita sem acento certo');
  }

  @IsTest
  static void telefoneCorrigidoNaoTrocaAChaveDoWhatsApp() {
    Lead l = novoLead();

    Test.startTest();
    STE_BotAtualizarCampo.Resultado r = atualizar(
      l.Id,
      'Telefone',
      '(11) 3333-9999'
    );
    Test.stopTest();

    Assert.isTrue(r.sucesso, r.mensagem);
    Lead depois = [
      SELECT MobilePhone, STE_Telefone_E164__c
      FROM Lead
      WHERE Id = :l.Id
    ];
    Assert.areEqual('(11) 3333-9999', depois.MobilePhone);
    Assert.areEqual(
      '5511988880001',
      depois.STE_Telefone_E164__c,
      'a chave do WhatsApp não pode mudar'
    );
  }

  @IsTest
  static void corrigeContatoTambem() {
    Contact c = new Contact(
      LastName = 'testes atualizar contato',
      Email = 'testes.contato@example.invalid'
    );
    insert c;

    Test.startTest();
    STE_BotAtualizarCampo.Resultado r = atualizar(
      c.Id,
      'Nome',
      'testes contato corrigido'
    );
    Test.stopTest();

    Assert.isTrue(r.sucesso, r.mensagem);
    Assert.areEqual(
      'testes contato corrigido',
      [SELECT LastName FROM Contact WHERE Id = :c.Id].LastName
    );
  }

  @IsTest
  static void recusaValorQueNaoServe() {
    Lead l = novoLead();

    Test.startTest();
    STE_BotAtualizarCampo.Resultado email = atualizar(l.Id, 'Email', 'sem-arroba');
    STE_BotAtualizarCampo.Resultado telefone = atualizar(l.Id, 'Telefone', '123');
    STE_BotAtualizarCampo.Resultado genero = atualizar(l.Id, 'Genero', 'qualquer');
    STE_BotAtualizarCampo.Resultado nome = atualizar(l.Id, 'Nome', 'x');
    Test.stopTest();

    Assert.isFalse(email.sucesso, 'e-mail sem arroba não deveria passar');
    Assert.isFalse(telefone.sucesso, 'telefone curto não deveria passar');
    Assert.isFalse(genero.sucesso, 'gênero fora da lista não deveria passar');
    Assert.isFalse(nome.sucesso, 'nome de uma letra não deveria passar');
    Lead depois = [
      SELECT Email, MobilePhone, STE_Genero__c, LastName
      FROM Lead
      WHERE Id = :l.Id
    ];
    Assert.areEqual(
      'testes.atualizar@example.invalid',
      depois.Email,
      'nada deveria ter sido gravado'
    );
    Assert.areEqual('Masculino', depois.STE_Genero__c);
  }

  @IsTest
  static void recusaEntradaSemRegistroOuSemCampo() {
    Test.startTest();
    STE_BotAtualizarCampo.Resultado semId = atualizar(null, 'Nome', 'testes');
    STE_BotAtualizarCampo.Resultado idDeOutroObjeto = atualizar(
      UserInfo.getUserId(),
      'Nome',
      'testes'
    );
    STE_BotAtualizarCampo.Resultado campoDesconhecido = atualizar(
      novoLead().Id,
      'CPF',
      '123'
    );
    List<STE_BotAtualizarCampo.Resultado> vazio = STE_BotAtualizarCampo.atualizar(
      new List<STE_BotAtualizarCampo.Entrada>()
    );
    Test.stopTest();

    Assert.isFalse(semId.sucesso);
    Assert.isFalse(idDeOutroObjeto.sucesso, 'só Lead e Contato são aceitos');
    Assert.isFalse(campoDesconhecido.sucesso);
    Assert.isTrue(vazio.isEmpty());
  }

  @IsTest
  static void recusaValorEmBranco() {
    Test.startTest();
    STE_BotAtualizarCampo.Resultado r = atualizar(novoLead().Id, 'Nome', '   ');
    Test.stopTest();

    Assert.isFalse(r.sucesso, 'valor em branco não deveria passar');
  }
}