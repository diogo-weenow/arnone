/**
 * Upload enriquecimento Lemit — testes do processamento (batch).
 *
 * Cobre criação com distribuição + Task "1ª Ligação", OVERWRITE, FILL_BLANK,
 * célula vazia que nunca apaga, atualização que não redistribui, FLS efetiva
 * (stripInaccessible barrando o campo sem edit), idempotência, bulk e seleção
 * de múltiplos. Campos da matriz: NumberOfEmployees (OVERWRITE) e Phone
 * (FILL_BLANK) — ambos existem nesta org.
 */
@IsTest
private class SOLEnriquecimentoBatchTest {
  @TestSetup
  static void semear() {
    SOLEnriquecimentoTestFactory.atribuirPsAoUsuarioAtual();
    SOLEnriquecimentoTestFactory.semearSingleton();
  }

  private static Map<String, String> criar(String funcionarios) {
    return new Map<String, String>{
      'NumberOfEmployees' => funcionarios,
      'Company' => 'Nova Empresa Lemit',
      'LastName' => 'Novo Contato'
    };
  }

  private static void rodar(Id loteId) {
    Test.startTest();
    Database.executeBatch(new SOLEnriquecimentoBatch(loteId), 50);
    Test.stopTest();
  }

  // ---------------------------------------------------------------- CRIAR (3)

  @IsTest
  static void semMatchCriaLeadSOLComDistribuicaoETarefa() {
    List<Id> vendedores = SOLEnriquecimentoTestFactory.montarFila(2);
    SOLEnriquecimentoTestFactory.aplicarOverrides();
    String cnpj = '11222333000181';

    SOL_Enriquecimento_Lote__c lote = SOLEnriquecimentoTestFactory.novoLote();
    insert SOLEnriquecimentoTestFactory.linhaCriar(lote.Id, 1, cnpj, criar('1000'));

    rodar(lote.Id);

    Lead criado = [
      SELECT
        Id,
        OwnerId,
        RecordType.DeveloperName,
        Unidade_Origem__c,
        SOL_CNPJ_Normalizado__c,
        CNPJ__c,
        NumberOfEmployees
      FROM Lead
      WHERE SOL_CNPJ_Normalizado__c = :cnpj AND IsConverted = FALSE
      LIMIT 1
    ];
    Assert.areEqual('SOL', criado.RecordType.DeveloperName, 'Deve ser Record Type SOL.');
    Assert.areEqual('SOL', criado.Unidade_Origem__c, 'Unidade de origem deve ser SOL.');
    Assert.areEqual(cnpj, criado.SOL_CNPJ_Normalizado__c, 'CNPJ normalizado errado.');
    Assert.areEqual(1000, criado.NumberOfEmployees, 'Campo de criação não aplicado.');
    Assert.isTrue(
      new Set<Id>(vendedores).contains(criado.OwnerId),
      'O round-robin deveria ter atribuído a um vendedor da fila.'
    );
    Integer tarefas = [
      SELECT COUNT()
      FROM Task
      WHERE WhoId = :criado.Id AND Subject = '1ª Ligação'
    ];
    Assert.areEqual(1, tarefas, 'Deveria existir a Task "1ª Ligação".');

    SOL_Enriquecimento_Lote__c recar = [
      SELECT Qtd_Criados__c, Status__c
      FROM SOL_Enriquecimento_Lote__c
      WHERE Id = :lote.Id
    ];
    Assert.areEqual(1, recar.Qtd_Criados__c, 'Contagem de criados errada.');
    Assert.areEqual('Concluído', recar.Status__c, 'Lote deveria concluir.');
  }

  // ---------------------------------------------------------------- OVERWRITE (7)

  @IsTest
  static void overwriteSobrescreveQuandoCelulaTemValor() {
    SOLEnriquecimentoTestFactory.montarFila(2);
    SOLEnriquecimentoTestFactory.aplicarOverrides();
    Lead a = SOLEnriquecimentoTestFactory.novoLeadSOL('A', 'Emp A', '11222333000181');
    update new Lead(Id = a.Id, NumberOfEmployees = 100);

    SOL_Enriquecimento_Lote__c lote = SOLEnriquecimentoTestFactory.novoLote();
    insert SOLEnriquecimentoTestFactory.linhaAtualizar(
      lote.Id,
      1,
      '11222333000181',
      new Map<String, String>{ 'NumberOfEmployees' => '250' },
      new List<Id>{ a.Id }
    );

    rodar(lote.Id);

    Assert.areEqual(
      250,
      [SELECT NumberOfEmployees FROM Lead WHERE Id = :a.Id].NumberOfEmployees,
      'OVERWRITE deveria sobrescrever para 250.'
    );
  }

  // ---------------------------------------------------------------- FILL_BLANK (8)

  @IsTest
  static void fillBlankSoPreencheVazio() {
    SOLEnriquecimentoTestFactory.montarFila(2);
    SOLEnriquecimentoTestFactory.aplicarOverrides();
    Lead comFone = SOLEnriquecimentoTestFactory.novoLeadSOL('F1', 'Emp F1', '11222333000181');
    update new Lead(Id = comFone.Id, Phone = '1111');
    Lead semFone = SOLEnriquecimentoTestFactory.novoLeadSOL('F2', 'Emp F2', '11444777000161');

    SOL_Enriquecimento_Lote__c lote = SOLEnriquecimentoTestFactory.novoLote();
    insert new List<SOL_Enriquecimento_Linha__c>{
      SOLEnriquecimentoTestFactory.linhaAtualizar(
        lote.Id,
        1,
        '11222333000181',
        new Map<String, String>{ 'Phone' => '9999' },
        new List<Id>{ comFone.Id }
      ),
      SOLEnriquecimentoTestFactory.linhaAtualizar(
        lote.Id,
        2,
        '11444777000161',
        new Map<String, String>{ 'Phone' => '9999' },
        new List<Id>{ semFone.Id }
      )
    };

    rodar(lote.Id);

    Assert.areEqual(
      '1111',
      [SELECT Phone FROM Lead WHERE Id = :comFone.Id].Phone,
      'FILL_BLANK não deveria sobrescrever um telefone já preenchido.'
    );
    Assert.areEqual(
      '9999',
      [SELECT Phone FROM Lead WHERE Id = :semFone.Id].Phone,
      'FILL_BLANK deveria preencher o telefone vazio.'
    );
  }

  // ---------------------------------------------------------------- célula vazia (9)

  @IsTest
  static void celulaVaziaNuncaApaga() {
    SOLEnriquecimentoTestFactory.montarFila(2);
    SOLEnriquecimentoTestFactory.aplicarOverrides();
    Lead a = SOLEnriquecimentoTestFactory.novoLeadSOL('A', 'Emp A', '11222333000181');
    update new Lead(Id = a.Id, NumberOfEmployees = 500, Phone = '1234');

    SOL_Enriquecimento_Lote__c lote = SOLEnriquecimentoTestFactory.novoLote();
    insert SOLEnriquecimentoTestFactory.linhaAtualizar(
      lote.Id,
      1,
      '11222333000181',
      new Map<String, String>{ 'NumberOfEmployees' => '', 'Phone' => '' },
      new List<Id>{ a.Id }
    );

    rodar(lote.Id);

    Lead r = [SELECT NumberOfEmployees, Phone FROM Lead WHERE Id = :a.Id];
    Assert.areEqual(500, r.NumberOfEmployees, 'OVERWRITE com célula vazia não pode apagar.');
    Assert.areEqual('1234', r.Phone, 'FILL_BLANK com célula vazia não pode apagar.');
  }

  // ---------------------------------------------------------------- update não redistribui (10)

  @IsTest
  static void atualizarNaoRedistribuiNemCriaNovaTarefa() {
    SOLEnriquecimentoTestFactory.montarFila(2);
    SOLEnriquecimentoTestFactory.aplicarOverrides();
    Lead a = SOLEnriquecimentoTestFactory.novoLeadSOL('A', 'Emp A', '11222333000181');
    Lead antes = [SELECT OwnerId, Status FROM Lead WHERE Id = :a.Id];
    Integer tarefasAntes = [
      SELECT COUNT()
      FROM Task
      WHERE WhoId = :a.Id AND Subject = '1ª Ligação'
    ];

    SOL_Enriquecimento_Lote__c lote = SOLEnriquecimentoTestFactory.novoLote();
    insert SOLEnriquecimentoTestFactory.linhaAtualizar(
      lote.Id,
      1,
      '11222333000181',
      new Map<String, String>{ 'NumberOfEmployees' => '999' },
      new List<Id>{ a.Id }
    );

    rodar(lote.Id);

    Lead depois = [SELECT OwnerId, Status, NumberOfEmployees FROM Lead WHERE Id = :a.Id];
    Assert.areEqual(antes.OwnerId, depois.OwnerId, 'Owner não pode mudar na atualização.');
    Assert.areEqual(antes.Status, depois.Status, 'Status não pode mudar na atualização.');
    Assert.areEqual(999, depois.NumberOfEmployees, 'O enriquecimento deveria ter gravado.');
    Integer tarefasDepois = [
      SELECT COUNT()
      FROM Task
      WHERE WhoId = :a.Id AND Subject = '1ª Ligação'
    ];
    Assert.areEqual(
      tarefasAntes,
      tarefasDepois,
      'Atualização não pode criar nova Task "1ª Ligação".'
    );
  }

  // ---------------------------------------------------------------- FLS efetiva (11)

  @IsTest
  static void flsBarraCampoSemEdit() {
    Profile p = [
      SELECT Id
      FROM Profile
      WHERE Name = 'Minimum Access - Salesforce'
      LIMIT 1
    ];
    User restrito = new User(
      FirstName = 'FLS',
      LastName = 'Restrito',
      Alias = 'flsr',
      Email = 'fls.restrito@arnone.invalid',
      Username = 'fls.restrito.' +
        String.valueOf(Math.abs(Crypto.getRandomInteger())) +
        '@arnone.lemit.test.invalid',
      ProfileId = p.Id,
      TimeZoneSidKey = 'America/Sao_Paulo',
      LocaleSidKey = 'pt_BR',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'pt_BR'
    );

    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert restrito;
      PermissionSet ps = new PermissionSet(
        Name = 'Enriq_FLS_Teste',
        Label = 'Enriq FLS Teste'
      );
      insert ps;
      insert new ObjectPermissions(
        ParentId = ps.Id,
        SobjectType = 'Lead',
        PermissionsRead = true,
        PermissionsEdit = true,
        PermissionsCreate = true
      );
      insert new List<FieldPermissions>{
        new FieldPermissions(
          ParentId = ps.Id,
          SobjectType = 'Lead',
          Field = 'Lead.NumberOfEmployees',
          PermissionsRead = true,
          PermissionsEdit = false
        ),
        new FieldPermissions(
          ParentId = ps.Id,
          SobjectType = 'Lead',
          Field = 'Lead.Phone',
          PermissionsRead = true,
          PermissionsEdit = true
        )
      };
      insert new PermissionSetAssignment(
        AssigneeId = restrito.Id,
        PermissionSetId = ps.Id
      );
    }

    Id leadId;
    System.runAs(restrito) {
      SOLEnriquecimentoController.matrizOverride = SOLEnriquecimentoTestFactory.matriz();
      // Lead simples (sem RT SOL) para isolar a FLS da distribuição.
      Lead l = new Lead(
        LastName = 'Alvo FLS',
        Company = 'Emp FLS',
        NumberOfEmployees = 100
      );
      insert l; // DML comum: ignora FLS/CRUD no setup.
      leadId = l.Id;

      SOL_Enriquecimento_Lote__c lote = new SOL_Enriquecimento_Lote__c(
        Status__c = 'Em preview'
      );
      insert lote;
      SOL_Enriquecimento_Linha__c linha = SOLEnriquecimentoTestFactory.linhaAtualizar(
        lote.Id,
        1,
        '11222333000181',
        new Map<String, String>{ 'NumberOfEmployees' => '999', 'Phone' => '7777' },
        new List<Id>{ l.Id }
      );
      insert linha;

      Test.startTest();
      SOLEnriquecimentoBatch.processarEscopo(
        new List<SOL_Enriquecimento_Linha__c>{ linha },
        new SOLEnriquecimentoBatch.Acumulador()
      );
      Test.stopTest();
    }

    Lead r = [SELECT NumberOfEmployees, Phone FROM Lead WHERE Id = :leadId];
    Assert.areEqual(
      100,
      r.NumberOfEmployees,
      'Sem FLS de edição, NumberOfEmployees deveria ser barrado (mantém 100).'
    );
    Assert.areEqual(
      '7777',
      r.Phone,
      'Com FLS de edição, Phone deveria ter sido gravado.'
    );
  }

  // ---------------------------------------------------------------- idempotência (12)

  @IsTest
  static void reprocessarNaoDuplicaCriacao() {
    SOLEnriquecimentoTestFactory.montarFila(2);
    SOLEnriquecimentoTestFactory.aplicarOverrides();
    String cnpj = '11222333000181';

    SOL_Enriquecimento_Lote__c lote = SOLEnriquecimentoTestFactory.novoLote();
    insert SOLEnriquecimentoTestFactory.linhaCriar(lote.Id, 1, cnpj, criar('500'));

    Test.startTest();
    Database.executeBatch(new SOLEnriquecimentoBatch(lote.Id), 50);
    Test.stopTest();

    Integer apos1 = [
      SELECT COUNT()
      FROM Lead
      WHERE SOL_CNPJ_Normalizado__c = :cnpj
    ];
    Assert.areEqual(1, apos1, 'Deveria criar exatamente 1 Lead.');

    // Reprocessa síncrono — a linha já tem Lead_Resultante__c preenchido.
    SOLEnriquecimentoBatch.processarEscopo(
      [
        SELECT
          Id,
          CNPJ_Normalizado__c,
          Payload_JSON__c,
          Acao__c,
          Leads_Alvo__c,
          Lead_Resultante__c,
          Resultado_Processamento__c
        FROM SOL_Enriquecimento_Linha__c
        WHERE Lote__c = :lote.Id AND Lead_Resultante__c = NULL
      ],
      new SOLEnriquecimentoBatch.Acumulador()
    );

    Integer apos2 = [
      SELECT COUNT()
      FROM Lead
      WHERE SOL_CNPJ_Normalizado__c = :cnpj
    ];
    Assert.areEqual(1, apos2, 'Reprocessar não pode duplicar a criação.');
  }

  // ---------------------------------------------------------------- bulk (13)

  @IsTest
  static void bulkMisturaAtualizarECriar() {
    List<Id> vendedores = SOLEnriquecimentoTestFactory.montarFila(3);
    SOLEnriquecimentoTestFactory.aplicarOverrides();
    String statusInicial = SOLEnriquecimentoTestFactory.statusPadrao();
    Id rt = SOLEnriquecimentoTestFactory.rtSol();

    // 100 Leads SOL existentes (um único insert dispara a distribuição em bulk).
    List<Lead> existentes = new List<Lead>();
    for (Integer i = 0; i < 100; i++) {
      String cnpj = String.valueOf(10000000000000L + i);
      existentes.add(
        new Lead(
          RecordTypeId = rt,
          LastName = 'Exist ' + i,
          Company = 'Emp E ' + i,
          CNPJ__c = SOLEnriquecimentoUtil.formatarCnpj(cnpj),
          Status = statusInicial
        )
      );
    }
    insert existentes;

    SOL_Enriquecimento_Lote__c lote = SOLEnriquecimentoTestFactory.novoLote();
    List<SOL_Enriquecimento_Linha__c> linhas = new List<SOL_Enriquecimento_Linha__c>();
    for (Integer i = 0; i < 100; i++) {
      String cnpj = String.valueOf(10000000000000L + i);
      linhas.add(
        SOLEnriquecimentoTestFactory.linhaAtualizar(
          lote.Id,
          i + 1,
          cnpj,
          new Map<String, String>{ 'NumberOfEmployees' => '300' },
          new List<Id>{ existentes[i].Id }
        )
      );
    }
    for (Integer i = 0; i < 100; i++) {
      String cnpj = String.valueOf(20000000000000L + i);
      linhas.add(
        SOLEnriquecimentoTestFactory.linhaCriar(lote.Id, 100 + i + 1, cnpj, criar('400'))
      );
    }
    insert linhas;

    // Em teste, o batch só pode resultar em UM execute(); usamos scope 200 para
    // processar as 200 linhas numa única execução — um teste de bulk mais forte.
    Test.startTest();
    Database.executeBatch(new SOLEnriquecimentoBatch(lote.Id), 200);
    Test.stopTest();

    SOL_Enriquecimento_Lote__c recar = [
      SELECT Qtd_Atualizados__c, Qtd_Criados__c, Qtd_Erros__c
      FROM SOL_Enriquecimento_Lote__c
      WHERE Id = :lote.Id
    ];
    Assert.areEqual(100, recar.Qtd_Atualizados__c, 'Deveria atualizar 100 linhas.');
    Assert.areEqual(100, recar.Qtd_Criados__c, 'Deveria criar 100 Leads.');
    Assert.areEqual(0, recar.Qtd_Erros__c, 'Não deveria haver erros no bulk.');

    Integer criadosDistribuidos = [
      SELECT COUNT()
      FROM Lead
      WHERE
        SOL_CNPJ_Normalizado__c LIKE '2000000000%'
        AND OwnerId IN :vendedores
    ];
    Assert.areEqual(
      100,
      criadosDistribuidos,
      'Os 100 criados deveriam ter sido distribuídos aos vendedores.'
    );
  }

  // ---------------------------------------------------------------- múltiplos: só selecionados (2)

  @IsTest
  static void multiploAtualizaSoSelecionados() {
    SOLEnriquecimentoTestFactory.montarFila(2);
    SOLEnriquecimentoTestFactory.aplicarOverrides();
    String cnpj = '11222333000181';
    Lead a = SOLEnriquecimentoTestFactory.novoLeadSOL('M1', 'Emp M1', cnpj);
    Lead b = SOLEnriquecimentoTestFactory.novoLeadSOL('M2', 'Emp M2', cnpj);
    update new List<Lead>{
      new Lead(Id = a.Id, NumberOfEmployees = 1),
      new Lead(Id = b.Id, NumberOfEmployees = 1)
    };

    SOL_Enriquecimento_Lote__c lote = SOLEnriquecimentoTestFactory.novoLote();
    // Leads_Alvo com 'a' selecionado e 'b' NÃO selecionado.
    SOL_Enriquecimento_Linha__c linha = new SOL_Enriquecimento_Linha__c(
      Lote__c = lote.Id,
      Numero_Linha__c = 1,
      CNPJ_Original__c = cnpj,
      CNPJ_Normalizado__c = cnpj,
      Payload_JSON__c = JSON.serialize(
        new Map<String, String>{ 'NumberOfEmployees' => '888' }
      ),
      Resultado_Match__c = 'MATCH_MULTIPLO',
      Acao__c = 'ATUALIZAR',
      Leads_Alvo__c = SOLEnriquecimentoTestFactory.alvosJson(
        new List<Id>{ a.Id, b.Id },
        new List<Boolean>{ true, false }
      )
    );
    insert linha;

    rodar(lote.Id);

    Assert.areEqual(
      888,
      [SELECT NumberOfEmployees FROM Lead WHERE Id = :a.Id].NumberOfEmployees,
      'O Lead selecionado deveria ser atualizado.'
    );
    Assert.areEqual(
      1,
      [SELECT NumberOfEmployees FROM Lead WHERE Id = :b.Id].NumberOfEmployees,
      'O Lead NÃO selecionado deveria ficar intacto.'
    );
  }
}
