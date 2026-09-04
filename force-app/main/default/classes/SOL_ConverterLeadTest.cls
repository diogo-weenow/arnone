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
    // A distribuição do CLICKUP-9394 roda no after-save. Sem roster ativo nesta
    // transação ela cai no fallback e estaciona o lead na FILA — e a plataforma
    // não converte registro de fila ("Converted objects can only be owned by
    // users"). Em produção o round-robin entrega a um vendedor de verdade; aqui
    // o dono precisa ser reposto à mão para o cenário ser o real.
    l.OwnerId = UserInfo.getUserId();
    // O CLICKUP-9419 exige reunião comercial realizada para converter. A tela
    // registra isso concluindo a tarefa de reunião; a fixture grava o marco
    // direto, no mesmo espírito com que já grava o status da procuração.
    l.SOL_Data_Reuniao_Realizada__c = Datetime.now().addDays(-1);
    update l;
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

  /**
   * A VR SOL_Lead_Exige_CNPJ não deixa gravar lead SOL sem CNPJ, então esse
   * estado não existe no banco — e a fixture antiga tentava criá-lo, falhando
   * com MISSING_ARGUMENT porque o insert nem chegava a ter Id. O portão do
   * conversor continua valendo a pena testar: ele é a segunda barreira, para o
   * caso de o dado chegar por integração. Testamos o portão direto, com o CNPJ
   * apagado só em memória — o registro no banco segue íntegro.
   */
  @IsTest
  static void naoConverteSemCnpj() {
    Lead l = leadComProcuracao();
    Id leadId = l.Id;

    Test.startTest();
    Lead emMemoria = Database.query(
      'SELECT ' + SOL_ConverterLead.CAMPOS_LEAD + ' FROM Lead WHERE Id = :leadId'
    );
    emMemoria.CNPJ__c = null;
    String impedimento = SOL_ConverterLead.impedimentoPara(emMemoria, 1);
    Test.stopTest();

    Assert.isNotNull(impedimento, 'Sem CNPJ o portão tem de impedir.');
    Assert.isTrue(
      impedimento.contains('CNPJ'),
      'Sem CNPJ não há como evitar duplicata: ' + impedimento
    );
    Assert.isNotNull(
      [SELECT CNPJ__c FROM Lead WHERE Id = :leadId].CNPJ__c,
      'O registro gravado continua com o CNPJ: só a cópia em memória foi alterada.'
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

    // O Id tem de ir tipado: ContentDocumentLink só aceita filtro por Id, e
    // ligar a String de `oportunidadeId` faz a consulta ser recusada com
    // "Implementation restriction".
    Id oportunidadeId = r.oportunidadeId;
    List<ContentDocumentLink> naOportunidade = [
      SELECT Id
      FROM ContentDocumentLink
      WHERE LinkedEntityId = :oportunidadeId
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

  /**
   * D1 da homologação E2E: o vendedor SOL de verdade — perfil Standard, sem
   * "Modify All Data", e com um único permission set: o PS_SOL_Comercial que a
   * mensagem SEM_PERMISSAO manda pedir ao administrador. Nada de PS_Comercial
   * nem de permissão de outras BUs.
   */
  private static User vendedorSOL() {
    Profile p = [
      SELECT Id
      FROM Profile
      WHERE UserType = 'Standard' AND PermissionsModifyAllData = FALSE
      LIMIT 1
    ];
    User u = new User(
      ProfileId = p.Id,
      LastName = 'Vendedor SOL',
      Alias = 'vendsol',
      Email = 'vendedor.sol@exemplo.com',
      Username = 'vendedor.sol.' +
        DateTime.now().getTime() +
        '@exemplo.com.teste',
      TimeZoneSidKey = 'America/Sao_Paulo',
      LocaleSidKey = 'pt_BR',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'pt_BR'
    );
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert u;
      insert new PermissionSetAssignment(
        AssigneeId = u.Id,
        PermissionSetId = [
          SELECT Id
          FROM PermissionSet
          WHERE Name = 'PS_SOL_Comercial'
          LIMIT 1
        ]
        .Id
      );
    }
    return u;
  }

  /**
   * D1 da homologação E2E: antes da correção, este caminho morria em
   * "fields being inaccessible on Sobject Account … CNPJ__c,
   * Unidades_Atendidas__c", porque o PS_SOL_Comercial não concedia edição
   * nesses dois campos e o conversor os grava ao criar a Conta. Uma vendedora
   * ativa no roster (só com esse PS) não conseguia converter os leads que o
   * round-robin lhe entregava.
   */
  @IsTest
  static void vendedorComApenasOPsComercialConverte() {
    Lead l = leadComProcuracao();
    User vendedor = vendedorSOL();
    // O lead nasce do round-robin já na mão do vendedor. A fixture é montada
    // como admin de propósito: só a conversão roda no contexto restrito.
    l.OwnerId = vendedor.Id;
    update l;

    SOL_ConverterLead.Resultado r;
    Test.startTest();
    System.runAs(vendedor) {
      r = SOL_ConverterLead.converter(
        new List<SOL_ConverterLead.Pedido>{ pedidoDe(l.Id, null) }
      )[0];
    }
    Test.stopTest();

    Assert.isTrue(
      r.convertido,
      'O vendedor com apenas PS_SOL_Comercial deveria converter. Mensagem: ' +
        r.mensagem
    );
    Assert.isNotNull(r.contaId, 'Conta deveria ter sido criada.');
    Assert.isNotNull(r.contatoId, 'Contato deveria ter sido criado.');
    Assert.isNotNull(
      r.oportunidadeId,
      'Oportunidade deveria ter sido criada.'
    );

    Lead depois = [
      SELECT IsConverted, ConvertedAccountId, ConvertedContactId, ConvertedOpportunityId
      FROM Lead
      WHERE Id = :l.Id
    ];
    Assert.isTrue(depois.IsConverted, 'O lead deveria estar convertido.');
    Assert.areEqual(
      r.contaId,
      String.valueOf(depois.ConvertedAccountId),
      'A Conta do resultado é a Conta da conversão.'
    );
    Assert.areEqual(
      r.contatoId,
      String.valueOf(depois.ConvertedContactId),
      'O Contato do resultado é o Contato da conversão.'
    );
    Assert.areEqual(
      r.oportunidadeId,
      String.valueOf(depois.ConvertedOpportunityId),
      'A Oportunidade do resultado é a da conversão.'
    );

    // O CNPJ é justamente o campo que faltava: tem de chegar gravado na Conta.
    Account conta = [
      SELECT CNPJ__c, Name
      FROM Account
      WHERE Id = :depois.ConvertedAccountId
    ];
    Assert.isNotNull(
      conta.CNPJ__c,
      'O CNPJ tem de chegar gravado na Conta nova — é o campo que faltava no PS.'
    );
    Assert.isTrue(
      SOL_ConverterLead.variantesDe(CNPJ_CRU).contains(conta.CNPJ__c),
      'O CNPJ da Conta é o do lead, numa das duas grafias: ' + conta.CNPJ__c
    );
  }

  /**
   * D1, reaproveitamento: quando a Conta do CNPJ já existe, o vendedor com
   * apenas PS_SOL_Comercial precisa conseguir reaproveitá-la — o conversor
   * também grava campos de Account nesse caminho.
   */
  @IsTest
  static void vendedorComApenasOPsComercialReaproveitaConta() {
    Lead l = leadComProcuracao();
    User vendedor = vendedorSOL();
    // A Conta preexistente fica com o vendedor: o que o D1 corrige é FLS, não
    // compartilhamento. Achar Conta de OUTRA unidade depende do modelo de
    // sharing de Account da org, que esta correção não altera.
    Account existente = new Account(
      Name = 'Industria Teste LTDA',
      CNPJ__c = CNPJ_CRU,
      OwnerId = vendedor.Id
    );
    insert existente;

    l.OwnerId = vendedor.Id;
    update l;

    // O caminho real da tela: preparar sugere a Conta do CNPJ, converter recebe
    // a sugestão. As duas etapas rodam no contexto do vendedor, e é `preparar`
    // que consulta Account.CNPJ__c — justamente o campo do D1.
    SOL_PrepararConversao.Preparo p;
    SOL_ConverterLead.Resultado r;
    Test.startTest();
    System.runAs(vendedor) {
      p = SOL_PrepararConversao.preparar(new List<Id>{ l.Id })[0];
      r = SOL_ConverterLead.converter(
        new List<SOL_ConverterLead.Pedido>{
          pedidoDe(l.Id, (Id) p.contaSugeridaId)
        }
      )[0];
    }
    Test.stopTest();

    Assert.areEqual(
      existente.Id,
      (Id) p.contaSugeridaId,
      'O vendedor precisa achar a Conta pelo CNPJ normalizado. Impedimento: ' +
        p.impedimento
    );
    Assert.isTrue(r.convertido, 'Deveria converter. Mensagem: ' + r.mensagem);
    Assert.areEqual(
      existente.Id,
      Id.valueOf(r.contaId),
      'Deveria reaproveitar a Conta do mesmo CNPJ, não criar outra.'
    );
    Assert.areEqual(
      1,
      [
        SELECT COUNT()
        FROM Account
        WHERE CNPJ__c IN :SOL_ConverterLead.variantesDe(CNPJ_CRU)
      ],
      'Nenhuma Conta duplicada foi criada.'
    );
    Assert.isNotNull(r.contatoId, 'Contato deveria ter sido criado.');
    Assert.isNotNull(
      r.oportunidadeId,
      'Oportunidade deveria ter sido criada.'
    );
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