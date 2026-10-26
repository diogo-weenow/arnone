/**
 * Importação de leads — testes do processamento (batch).
 *
 * SOL: OVERWRITE, FILL_BLANK e célula vazia (9), criação com distribuição e
 * Task "1ª Ligação" (12), reprocessamento idempotente (15), OwnerId mapeado (16),
 * FLS efetiva sem Website (17) e 200 criações (18). STE: campos protegidos e
 * dono/RT intactos (22) e perfil que não cria (20). REGRA_ATRIBUICAO com perfil
 * ESG injetado (24).
 */
@IsTest
private class ImportacaoLeadsBatchTest {
  @TestSetup
  static void semear() {
    ImportacaoLeadsTestFactory.atribuirPs(
      UserInfo.getUserId(),
      new List<String>{
        ImportacaoLeadsTestFactory.PS_BASE,
        ImportacaoLeadsTestFactory.PS_SOL,
        ImportacaoLeadsTestFactory.PS_STE
      }
    );
    ImportacaoLeadsTestFactory.semearSingleton();
  }

  private static void rodar(Id loteId, Integer escopo) {
    Test.startTest();
    Database.executeBatch(new ImportacaoLeadsBatch(loteId), escopo);
    Test.stopTest();
  }

  private static Importacao_Linha__c linha(Id loteId) {
    return [
      SELECT Resultado_Processamento__c, Erro__c, Lead_Resultante__c, Acao__c
      FROM Importacao_Linha__c
      WHERE Lote__c = :loteId
      LIMIT 1
    ];
  }

  // ---------------------------------------------------------------- (9)

  @IsTest
  static void overwriteFillBlankECelulaVazia() {
    ImportacaoLeadsTestFactory.montarFila(2);
    ImportacaoLeadsTestFactory.aplicarOverridesSol();
    Lead a = ImportacaoLeadsTestFactory.novoLeadSOL('A', 'Emp A', ImportacaoLeadsTestFactory.CNPJ_A);
    Lead b = ImportacaoLeadsTestFactory.novoLeadSOL('B', 'Emp B', ImportacaoLeadsTestFactory.CNPJ_B);
    update new List<Lead>{
      new Lead(Id = a.Id, NumberOfEmployees = 100, Phone = '1111'),
      new Lead(Id = b.Id, NumberOfEmployees = 500, Phone = null, Website = 'antigo.com.br')
    };

    Importacao_Lote__c lote = ImportacaoLeadsTestFactory.novoLote('SOL_Generico');
    insert new List<Importacao_Linha__c>{
      // OVERWRITE grava; FILL_BLANK não sobrescreve Phone preenchido.
      ImportacaoLeadsTestFactory.linhaAtualizar(
        lote.Id, 1, ImportacaoLeadsTestFactory.CNPJ_A,
        new Map<String, String>{ 'NumberOfEmployees' => '250', 'Phone' => '9999' },
        new List<Id>{ a.Id }
      ),
      // Célula vazia não apaga; FILL_BLANK preenche Phone vazio.
      ImportacaoLeadsTestFactory.linhaAtualizar(
        lote.Id, 2, ImportacaoLeadsTestFactory.CNPJ_B,
        new Map<String, String>{ 'NumberOfEmployees' => '', 'Website' => '', 'Phone' => '7777' },
        new List<Id>{ b.Id }
      )
    };

    rodar(lote.Id, 50);

    Lead ra = [SELECT NumberOfEmployees, Phone FROM Lead WHERE Id = :a.Id];
    Lead rb = [SELECT NumberOfEmployees, Phone, Website FROM Lead WHERE Id = :b.Id];
    Assert.areEqual(250, ra.NumberOfEmployees, 'OVERWRITE sobrescreve.');
    Assert.areEqual('1111', ra.Phone, 'FILL_BLANK não sobrescreve.');
    Assert.areEqual(500, rb.NumberOfEmployees, 'Célula vazia não apaga (OVERWRITE).');
    Assert.areEqual('antigo.com.br', rb.Website, 'Célula vazia não apaga (FILL_BLANK).');
    Assert.areEqual('7777', rb.Phone, 'FILL_BLANK preenche vazio.');
  }

  // ---------------------------------------------------------------- (12)

  @IsTest
  static void criarLeadSolDistribuidoComTarefa() {
    List<Id> vendedores = ImportacaoLeadsTestFactory.montarFila(2);
    ImportacaoLeadsTestFactory.aplicarOverridesSol();
    String cnpj = ImportacaoLeadsTestFactory.CNPJ_ALFA;

    Importacao_Lote__c lote = ImportacaoLeadsTestFactory.novoLote('SOL_Generico');
    insert ImportacaoLeadsTestFactory.linhaCriar(
      lote.Id, 1, cnpj, ImportacaoLeadsTestFactory.payloadCriar('1000')
    );

    rodar(lote.Id, 50);

    Lead criado = [
      SELECT
        Id,
        OwnerId,
        RecordType.DeveloperName,
        Unidade_Origem__c,
        CNPJ__c,
        CNPJ_Normalizado__c,
        NumberOfEmployees
      FROM Lead
      WHERE Id = :linha(lote.Id).Lead_Resultante__c
    ];
    Assert.areEqual('SOL', criado.RecordType.DeveloperName, 'RT SOL.');
    Assert.areEqual('SOL', criado.Unidade_Origem__c, 'Unidade SOL.');
    Assert.areEqual('12.ABC.345/01DE-35', criado.CNPJ__c, 'CNPJ formatado.');
    Assert.areEqual(cnpj, criado.CNPJ_Normalizado__c, 'CNPJ normalizado preenchido.');
    Assert.areEqual(1000, criado.NumberOfEmployees, 'Campo de criação aplicado.');
    Assert.isTrue(
      new Set<Id>(vendedores).contains(criado.OwnerId),
      'Dono é membro da fila de distribuição SOL.'
    );
    Assert.areEqual(
      1,
      [SELECT COUNT() FROM Task WHERE WhoId = :criado.Id AND Subject = '1ª Ligação'],
      'Task "1ª Ligação" criada.'
    );
    Importacao_Lote__c r = [SELECT Qtd_Criados__c, Status__c FROM Importacao_Lote__c WHERE Id = :lote.Id];
    Assert.areEqual(1, r.Qtd_Criados__c, 'Um criado.');
    Assert.areEqual('Concluído', r.Status__c, 'Lote concluído.');
  }

  // ---------------------------------------------------------------- (15)

  @IsTest
  static void reprocessarNaoDuplicaCriacao() {
    ImportacaoLeadsTestFactory.montarFila(2);
    ImportacaoLeadsTestFactory.aplicarOverridesSol();
    String cnpj = ImportacaoLeadsTestFactory.CNPJ_A;
    Importacao_Lote__c lote = ImportacaoLeadsTestFactory.novoLote('SOL_Generico');
    insert ImportacaoLeadsTestFactory.linhaCriar(
      lote.Id, 1, cnpj, ImportacaoLeadsTestFactory.payloadCriar('500')
    );

    rodar(lote.Id, 50);
    Assert.areEqual(1, [SELECT COUNT() FROM Lead WHERE CNPJ_Normalizado__c = :cnpj], 'Um lead criado.');

    // Reprocessa todas as linhas do lote, inclusive as já processadas.
    ImportacaoLeadsBatch.processarEscopo(
      [
        SELECT Id, Chave_Normalizada__c, Payload_JSON__c, Acao__c, Leads_Alvo__c, Lead_Resultante__c
        FROM Importacao_Linha__c
        WHERE Lote__c = :lote.Id
      ],
      new ImportacaoLeadsBatch.Acumulador(),
      'SOL_Generico'
    );
    Assert.areEqual(1, [SELECT COUNT() FROM Lead WHERE CNPJ_Normalizado__c = :cnpj], 'Reprocessar não cria outro.');
  }

  // ---------------------------------------------------------------- (16)

  @IsTest
  static void ownerIdMapeadoEhIgnoradoERegistrado() {
    ImportacaoLeadsTestFactory.montarFila(2);
    ImportacaoLeadsTestFactory.aplicarOverridesSol();
    Lead a = ImportacaoLeadsTestFactory.novoLeadSOL('A', 'Emp A', ImportacaoLeadsTestFactory.CNPJ_A);
    Id donoAntes = [SELECT OwnerId FROM Lead WHERE Id = :a.Id].OwnerId;

    Importacao_Lote__c lote = ImportacaoLeadsTestFactory.novoLote('SOL_Generico');
    insert ImportacaoLeadsTestFactory.linhaAtualizar(
      lote.Id, 1, ImportacaoLeadsTestFactory.CNPJ_A,
      new Map<String, String>{
        'OwnerId' => UserInfo.getUserId(),
        'NumberOfEmployees' => '42',
        'Company' => 'Coluna de criação',
        'LastName' => 'Coluna de criação'
      },
      new List<Id>{ a.Id }
    );
    rodar(lote.Id, 50);

    Lead r = [SELECT OwnerId, NumberOfEmployees FROM Lead WHERE Id = :a.Id];
    Assert.areEqual(donoAntes, r.OwnerId, 'OwnerId mapeado é ignorado.');
    Assert.areEqual(42, r.NumberOfEmployees, 'Os demais campos gravam.');
    Assert.isTrue(
      linha(lote.Id).Erro__c.contains('Campo protegido ignorado: OwnerId'),
      'O campo protegido é registrado na linha.'
    );
    Assert.isFalse(
      linha(lote.Id).Erro__c.contains('Company'),
      'Company/LastName (colunas de criação) não geram aviso na atualização.'
    );
  }

  // ---------------------------------------------------------------- (17)

  @IsTest
  static void semFlsEmWebsiteOsDemaisGravam() {
    User restrito = ImportacaoLeadsTestFactory.persona('fls', new List<String>());
    System.runAs(new User(Id = UserInfo.getUserId())) {
      PermissionSet ps = new PermissionSet(Name = 'Imp_FLS_Teste', Label = 'Imp FLS Teste');
      insert ps;
      insert new ObjectPermissions(
        ParentId = ps.Id,
        SobjectType = 'Lead',
        PermissionsRead = true,
        PermissionsEdit = true,
        PermissionsCreate = true
      );
      insert new List<FieldPermissions>{
        new FieldPermissions(ParentId = ps.Id, SobjectType = 'Lead', Field = 'Lead.Website', PermissionsRead = true, PermissionsEdit = false),
        new FieldPermissions(ParentId = ps.Id, SobjectType = 'Lead', Field = 'Lead.Phone', PermissionsRead = true, PermissionsEdit = true),
        new FieldPermissions(ParentId = ps.Id, SobjectType = 'Lead', Field = 'Lead.NumberOfEmployees', PermissionsRead = true, PermissionsEdit = true)
      };
      insert new PermissionSetAssignment(AssigneeId = restrito.Id, PermissionSetId = ps.Id);
    }

    Id leadId;
    System.runAs(restrito) {
      ImportacaoLeadsTestFactory.aplicarOverridesSol();
      // Lead sem RT SOL para isolar a FLS da distribuição.
      Lead l = new Lead(LastName = 'Alvo FLS', Company = 'Emp FLS');
      insert l;
      leadId = l.Id;
      Importacao_Lote__c lote = new Importacao_Lote__c(Status__c = 'Em preview', Perfil_Importacao__c = 'SOL_Generico');
      insert lote;
      Importacao_Linha__c li = ImportacaoLeadsTestFactory.linhaAtualizar(
        lote.Id, 1, ImportacaoLeadsTestFactory.CNPJ_A,
        new Map<String, String>{ 'Website' => 'novo.com.br', 'Phone' => '7777', 'NumberOfEmployees' => '9' },
        new List<Id>{ l.Id }
      );
      insert li;
      Test.startTest();
      ImportacaoLeadsBatch.processarEscopo(
        new List<Importacao_Linha__c>{ li },
        new ImportacaoLeadsBatch.Acumulador(),
        'SOL_Generico'
      );
      Test.stopTest();
    }

    Lead r = [SELECT Website, Phone, NumberOfEmployees FROM Lead WHERE Id = :leadId];
    Assert.isNull(r.Website, 'Sem FLS de edição, Website é barrado.');
    Assert.areEqual('7777', r.Phone, 'Phone grava.');
    Assert.areEqual(9, r.NumberOfEmployees, 'NumberOfEmployees grava.');
  }

  // ---------------------------------------------------------------- (18)

  @IsTest
  static void duzentasCriacoesSemEstourarLimite() {
    List<Id> vendedores = ImportacaoLeadsTestFactory.montarFila(3);
    ImportacaoLeadsTestFactory.aplicarOverridesSol();
    Importacao_Lote__c lote = ImportacaoLeadsTestFactory.novoLote('SOL_Generico');
    List<Importacao_Linha__c> linhas = new List<Importacao_Linha__c>();
    Set<String> cnpjs = new Set<String>();
    for (Integer i = 0; i < 200; i++) {
      String cnpj = ImportacaoLeadsTestFactory.cnpjValido(203040500000L + i);
      cnpjs.add(cnpj);
      linhas.add(
        ImportacaoLeadsTestFactory.linhaCriar(lote.Id, i + 1, cnpj, ImportacaoLeadsTestFactory.payloadCriar('400'))
      );
    }
    insert linhas;

    // Em teste o batch roda um único execute(); scope 200 = bulk real.
    rodar(lote.Id, 200);

    Importacao_Lote__c r = [SELECT Qtd_Criados__c, Qtd_Erros__c FROM Importacao_Lote__c WHERE Id = :lote.Id];
    Assert.areEqual(200, r.Qtd_Criados__c, '200 leads criados.');
    Assert.areEqual(0, r.Qtd_Erros__c, 'Sem erros no bulk.');
    Assert.areEqual(
      200,
      [SELECT COUNT() FROM Lead WHERE CNPJ_Normalizado__c IN :cnpjs AND OwnerId IN :vendedores],
      'Os 200 distribuídos.'
    );
  }

  // ---------------------------------------------------------------- (22, 20)

  @IsTest
  static void steCamposProtegidosIgnoradosEDonoIntacto() {
    Lead ste = ImportacaoLeadsTestFactory.novoLeadCpf('STE', 'Ste Prot', ImportacaoLeadsTestFactory.CPF_A);
    Lead antes = [SELECT OwnerId, RecordTypeId, CPF__c, STE_MessagingSession_Id__c FROM Lead WHERE Id = :ste.Id];

    Importacao_Lote__c lote = ImportacaoLeadsTestFactory.novoLote('STE_Atualizacao_CPF');
    insert new List<Importacao_Linha__c>{
      ImportacaoLeadsTestFactory.linhaAtualizar(
        lote.Id, 1, ImportacaoLeadsTestFactory.CPF_A,
        new Map<String, String>{
          'STE_Etapa_Bot__c' => 'Concluído',
          'STE_MessagingSession_Id__c' => '0Mwxx0000000001',
          'CPF__c' => '00000000000',
          'OwnerId' => UserInfo.getUserId(),
          'Email' => 'ste@arnone.invalid'
        },
        new List<Id>{ ste.Id }
      ),
      // Linha CRIAR forjada num perfil que não cria: nunca cria.
      ImportacaoLeadsTestFactory.linhaCriar(
        lote.Id, 2, ImportacaoLeadsTestFactory.CNPJ_B, ImportacaoLeadsTestFactory.payloadCriar('1')
      )
    };
    Integer leadsAntes = [SELECT COUNT() FROM Lead];

    rodar(lote.Id, 50);

    Lead r = [SELECT OwnerId, RecordTypeId, CPF__c, STE_MessagingSession_Id__c, Email FROM Lead WHERE Id = :ste.Id];
    Assert.areEqual(antes.OwnerId, r.OwnerId, 'Dono STE intacto.');
    Assert.areEqual(antes.RecordTypeId, r.RecordTypeId, 'RT STE intacto.');
    Assert.areEqual(antes.CPF__c, r.CPF__c, 'CPF__c protegido.');
    Assert.areEqual(antes.STE_MessagingSession_Id__c, r.STE_MessagingSession_Id__c, 'Sessão do bot protegida.');
    Assert.areEqual('ste@arnone.invalid', r.Email, 'Email (FILL_BLANK, vazio) gravado.');
    Assert.areEqual(leadsAntes, [SELECT COUNT() FROM Lead], 'Perfil STE nunca cria.');
    Importacao_Linha__c l1 = [SELECT Erro__c FROM Importacao_Linha__c WHERE Lote__c = :lote.Id AND Numero_Linha__c = 1];
    Assert.isTrue(l1.Erro__c.contains('STE_Etapa_Bot__c'), 'Etapa do bot registrada como protegida.');
    Assert.isTrue(l1.Erro__c.contains('STE_MessagingSession_Id__c'), 'Sessão registrada como protegida.');
    Assert.isTrue(l1.Erro__c.contains('CPF__c'), 'CPF registrado como protegido.');
    Importacao_Linha__c l2 = [SELECT Acao__c, Lead_Resultante__c FROM Importacao_Linha__c WHERE Lote__c = :lote.Id AND Numero_Linha__c = 2];
    Assert.areEqual('IGNORAR', l2.Acao__c, 'Linha CRIAR do STE vira IGNORAR.');
    Assert.isNull(l2.Lead_Resultante__c, 'Sem lead resultante.');
  }

  // ---------------------------------------------------------------- (24)

  @IsTest
  static void regraAtribuicaoComPerfilEsgInjetado() {
    ImportacaoLeadsTestFactory.injetarEsgAtivo();
    Id filaEsg = [SELECT Id FROM Group WHERE Type = 'Queue' AND DeveloperName = 'Fila_Leads_ESG' LIMIT 1].Id;

    Importacao_Lote__c lote = ImportacaoLeadsTestFactory.novoLote('ESG_Generico');
    insert ImportacaoLeadsTestFactory.linhaCriar(
      lote.Id, 1, ImportacaoLeadsTestFactory.CNPJ_A,
      new Map<String, String>{
        'Company' => 'Emp ESG Nova',
        'LastName' => 'Contato ESG',
        'Email' => 'esg@arnone.invalid'
      }
    );

    rodar(lote.Id, 50);

    Lead criado = [
      SELECT OwnerId, RecordType.DeveloperName, Unidade_Origem__c, Email
      FROM Lead
      WHERE Id = :linha(lote.Id).Lead_Resultante__c
    ];
    Assert.areEqual(filaEsg, criado.OwnerId, 'Dono pela regra de atribuição: Fila_Leads_ESG.');
    Assert.areEqual('ESG', criado.RecordType.DeveloperName, 'RT ESG.');
    Assert.areEqual('ESG', criado.Unidade_Origem__c, 'Unidade ESG.');
    Assert.areEqual('esg@arnone.invalid', criado.Email, 'Campo de criação da matriz ESG aplicado.');
  }

  @IsTest
  static void regraAtribuicaoInexistenteFalhaComMensagemClara() {
    ImportacaoLeadsTestFactory.injetarEsgAtivo();
    ImportacaoLeadsBatch.regraAtribuicaoNome = 'Regra_Que_Nao_Existe';
    Importacao_Lote__c lote = ImportacaoLeadsTestFactory.novoLote('ESG_Generico');
    insert ImportacaoLeadsTestFactory.linhaCriar(
      lote.Id, 1, ImportacaoLeadsTestFactory.CNPJ_B,
      new Map<String, String>{ 'Company' => 'Emp ESG', 'LastName' => 'Contato ESG' }
    );
    Integer leadsAntes = [SELECT COUNT() FROM Lead];

    rodar(lote.Id, 50);

    Importacao_Linha__c l = linha(lote.Id);
    Assert.areEqual('ERRO', l.Resultado_Processamento__c, 'Linha marcada com erro.');
    Assert.isTrue(l.Erro__c.contains('Regra_Que_Nao_Existe'), 'Mensagem cita a regra: ' + l.Erro__c);
    Assert.areEqual(leadsAntes, [SELECT COUNT() FROM Lead], 'Nenhum lead criado sem a regra.');
    Assert.areEqual(
      'Concluído com erros',
      [SELECT Status__c FROM Importacao_Lote__c WHERE Id = :lote.Id].Status__c,
      'Lote conclui com erros.'
    );
  }
}
