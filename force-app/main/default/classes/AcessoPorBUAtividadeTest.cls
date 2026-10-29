/**
 * ACESSO-POR-BU — Testes das atividades por unidade de negócio.
 *
 * Cobre:
 *   - Spike S1: a Restriction Rule `Acesso_BU_Tarefas`
 *     (`BU_Atividade__c = $User.Department`, userCriteria
 *     `$Permission.Atividades_Restritas_Por_BU = true`) discrimina por BU.
 *     A prova A/B foi feita rodando esta classe com a regra INATIVA (o teste
 *     `tarefaDeOutraBUFicaInvisivel` FALHA, porque a tarefa de Contato de Conta
 *     pública volta a aparecer) e ATIVA (passa). Apex não lê `RestrictionRule`.
 *   - Modelo BU + cargo: o PS da BU nao carrega restricao; o cargo Vendedor
 *     traz `SOL_Restringir_Tarefas_Ao_Proprietario` (tarefas e compromissos
 *     somente do proprietario), o Atendente e o Gestor trazem
 *     `Atividades_Restritas_Por_BU`. Exatamente uma restricao por usuario.
 *   - Convivência com o 9430: o vendedor continua vendo só as próprias.
 *   - Carimbo da BU pelos flows `Acesso_BU_Tarefa_Carimbar` e
 *     `Acesso_BU_Evento_Carimbar`, inclusive em volume (200 registros).
 *
 * Todos os usuários e registros são criados aqui; nenhum Id, perfil ou papel
 * fixado no código além de nomes de API (DeveloperName). Sem SeeAllData.
 */
@IsTest
private class AcessoPorBUAtividadeTest {
  private static final String CP_BU = 'Atividades_Restritas_Por_BU';
  private static final String CP_SOL = 'SOL_Restringir_Tarefas_Ao_Proprietario';
  private static final String CP_HIST = 'Ver_Historico';
  private static final String PREFIXO = 'APB_ATV';

  // ============================================================ semeadura

  @TestSetup
  static void semear() {
    List<User> usuarios = new List<User>{
      novoUsuario('advat', 'Comercial_ADV', 'ADV'),
      novoUsuario('advdir', 'Diretoria_ADV', 'ADV'),
      novoUsuario('steat', 'Comercial_STE', 'STE'),
      novoUsuario('solvend', 'Comercial_SOL', 'SOL'),
      novoUsuario('soldir', 'Diretoria_SOL', 'SOL'),
      novoUsuario('global', 'Diretoria_Grupo', null),
      novoUsuario('semcp', 'Comercial_STE', 'STE')
    };
    insert usuarios;
    Map<String, User> porApelido = new Map<String, User>();
    for (User u : usuarios) {
      porApelido.put(u.LastName.removeStart('Atv '), u);
    }

    // O atendente STE real tambem recebe PS_Atendimento e PS_Atendimento_Chat,
    // que exigem permission set licenses.
    atribuirLicencas(porApelido.get('steat').Id);

    // Modelo BU + cargo: PS da BU + exatamente um PS de cargo; o Diretor Global
    // usa o unico PSG. O controle (semcp) tem so o PS da BU, sem cargo.
    List<PermissionSetAssignment> psas = new List<PermissionSetAssignment>();
    psas.add(ps(porApelido.get('advat').Id, 'PS_ADV_Comercial'));
    psas.add(ps(porApelido.get('advat').Id, 'PS_Cargo_Vendedor'));
    psas.add(ps(porApelido.get('advdir').Id, 'PS_ADV_Comercial'));
    psas.add(ps(porApelido.get('advdir').Id, 'PS_Cargo_Gestor'));
    psas.add(ps(porApelido.get('steat').Id, 'PS_STE_Comercial'));
    psas.add(ps(porApelido.get('steat').Id, 'PS_Cargo_Atendente'));
    psas.add(ps(porApelido.get('steat').Id, 'PS_Atendimento'));
    psas.add(ps(porApelido.get('steat').Id, 'PS_Atendimento_Chat'));
    psas.add(ps(porApelido.get('solvend').Id, 'PS_SOL_Comercial'));
    psas.add(ps(porApelido.get('solvend').Id, 'PS_Cargo_Vendedor'));
    psas.add(ps(porApelido.get('soldir').Id, 'PS_SOL_Comercial'));
    psas.add(ps(porApelido.get('soldir').Id, 'PS_Cargo_Gestor'));
    psas.add(psg(porApelido.get('global').Id, 'PSG_Diretor_Global'));
    psas.add(ps(porApelido.get('semcp').Id, 'PS_STE_Comercial'));
    insert psas;

    System.runAs(new User(Id = UserInfo.getUserId())) {
      // Conta pública (OWD Account Edit) e Contato ControlledByParent: é o
      // caminho pelo qual a tarefa sem WhatId fica visível a qualquer interno.
      Account conta = new Account(
        Name = PREFIXO + ' Robson Teste Ltda',
        OwnerId = porApelido.get('advat').Id
      );
      insert conta;
      Contact robson = new Contact(
        LastName = PREFIXO + ' Robson',
        AccountId = conta.Id
      );
      insert robson;

      insert new List<Task>{
        // A BU NAO e informada aqui: ninguem tem FLS de edicao no campo, por
        // design. Quem carimba e o flow before-save (contexto de sistema),
        // pelo Department do dono, ja que nao ha Lead nem Oportunidade.
        new Task(
          Subject = PREFIXO + ' ADV contato Robson',
          OwnerId = porApelido.get('advat').Id,
          WhoId = robson.Id,
          Status = 'Open',
          Priority = 'Normal'
        ),
        new Task(
          Subject = PREFIXO + ' SOL do vendedor',
          OwnerId = porApelido.get('solvend').Id,
          WhoId = robson.Id,
          Status = 'Open',
          Priority = 'Normal'
        )
      };
    }
  }

  // ============================================================ helpers

  private static User novoUsuario(String apelido, String papel, String bu) {
    Profile padrao = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
    UserRole role = [SELECT Id FROM UserRole WHERE DeveloperName = :papel LIMIT 1];
    String unico = String.valueOf(Math.abs(Crypto.getRandomInteger()));
    return new User(
      FirstName = 'APB',
      LastName = 'Atv ' + apelido,
      CommunityNickname = ('apb' + apelido + unico).left(40),
      Alias = ('ap' + apelido).left(8),
      Email = 'apb.' + apelido + '@arnone.invalid',
      Username = 'apb.' + apelido + unico + '@arnone.acessoporbu.test.invalid',
      ProfileId = padrao.Id,
      UserRoleId = role.Id,
      Department = bu,
      TimeZoneSidKey = 'America/Sao_Paulo',
      LocaleSidKey = 'pt_BR',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'pt_BR'
    );
  }

  private static PermissionSetAssignment psg(Id userId, String nomePsg) {
    PermissionSetGroup g = [
      SELECT Id
      FROM PermissionSetGroup
      WHERE DeveloperName = :nomePsg
      LIMIT 1
    ];
    return new PermissionSetAssignment(
      AssigneeId = userId,
      PermissionSetGroupId = g.Id
    );
  }

  private static PermissionSetAssignment ps(Id userId, String nomePs) {
    PermissionSet p = [SELECT Id FROM PermissionSet WHERE Name = :nomePs LIMIT 1];
    return new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = p.Id);
  }

  private static void atribuirLicencas(Id userId) {
    List<PermissionSetLicenseAssign> psl = new List<PermissionSetLicenseAssign>();
    for (PermissionSetLicense l : [
      SELECT Id
      FROM PermissionSetLicense
      WHERE DeveloperName IN ('DEUnlimitedAccessPsl', 'EmbeddedServiceMessagingUserPsl')
    ]) {
      psl.add(new PermissionSetLicenseAssign(AssigneeId = userId, PermissionSetLicenseId = l.Id));
    }
    insert psl;
  }

  private static User usuario(String apelido) {
    return [
      SELECT Id, Department
      FROM User
      WHERE LastName = :('Atv ' + apelido) AND FirstName = 'APB'
      LIMIT 1
    ];
  }

  /** Tarefas do cenário vistas em modo de usuário (sharing + Restriction Rules). */
  private static Set<String> assuntosVisiveis() {
    Set<String> assuntos = new Set<String>();
    for (Task t : (List<Task>) Database.query(
      'SELECT Subject FROM Task WHERE Subject LIKE \'' + PREFIXO + '%\'',
      AccessLevel.USER_MODE
    )) {
      assuntos.add(t.Subject);
    }
    return assuntos;
  }

  private static Set<String> visiveisPara(String apelido) {
    Set<String> r;
    System.runAs(usuario(apelido)) {
      r = assuntosVisiveis();
    }
    return r;
  }

  // ============================================================ S1

  @IsTest
  static void tarefaDeOutraBUFicaInvisivel() {
    Set<String> vistas = visiveisPara('steat');
    Assert.isFalse(
      vistas.contains(PREFIXO + ' ADV contato Robson'),
      'S1: o atendente STE (Department STE, com ' + CP_BU + ') NAO pode ver a ' +
        'tarefa ADV pendurada no Contato Robson. Se viu, a Restriction Rule ' +
        'Acesso_BU_Tarefas esta inativa ou nao discrimina. Vistas: ' + vistas
    );
  }

  @IsTest
  static void controleSemPermissaoContinuaVendo() {
    // CONTROLE do S1: mesmo Department STE, mas SEM a custom permission. Se
    // este usuario deixar de ver, a regra incide sobre quem nao deveria.
    Set<String> vistas = visiveisPara('semcp');
    Assert.isTrue(
      vistas.contains(PREFIXO + ' ADV contato Robson'),
      'Controle: usuario sem ' + CP_BU + ' nao pode ser restringido. Vistas: ' + vistas
    );
  }

  @IsTest
  static void mesmaBUEDiretorVeemATarefa() {
    Assert.isTrue(
      visiveisPara('advat').contains(PREFIXO + ' ADV contato Robson'),
      'O atendente ADV (dono) tem de ver a tarefa ADV.'
    );
    Assert.isTrue(
      visiveisPara('advdir').contains(PREFIXO + ' ADV contato Robson'),
      'O diretor ADV tem de ver a tarefa ADV.'
    );
    Assert.isFalse(
      visiveisPara('advdir').contains(PREFIXO + ' SOL do vendedor'),
      'O diretor ADV nao pode ver a tarefa da BU SOL.'
    );
  }

  @IsTest
  static void diretorGlobalVeTodasAsTarefas() {
    Set<String> vistas = visiveisPara('global');
    Assert.areEqual(
      2,
      vistas.size(),
      'O Diretor Global nao tem a custom permission de BU e ve todas as ' +
        'tarefas do cenario. Vistas: ' + vistas
    );
  }

  // ============================================================ S2 e 9430

  @IsTest
  static void cargoDefineARestricaoDeAtividades() {
    Boolean dirSol;
    Boolean dirBu;
    Boolean dirHist;
    Boolean vendSol;
    Boolean vendBu;
    System.runAs(usuario('soldir')) {
      dirSol = FeatureManagement.checkPermission(CP_SOL);
      dirBu = FeatureManagement.checkPermission(CP_BU);
      dirHist = FeatureManagement.checkPermission(CP_HIST);
    }
    System.runAs(usuario('solvend')) {
      vendSol = FeatureManagement.checkPermission(CP_SOL);
      vendBu = FeatureManagement.checkPermission(CP_BU);
    }
    Assert.isFalse(dirSol, 'O diretor SOL (cargo Gestor) NAO pode ter ' + CP_SOL + ': o PS da BU nao carrega restricao.');
    Assert.isTrue(dirBu, 'O diretor SOL tem de receber ' + CP_BU + ' pelo cargo Gestor.');
    Assert.isTrue(dirHist, 'O diretor SOL tem de receber ' + CP_HIST + '.');
    Assert.isTrue(vendSol, 'O vendedor SOL recebe a restricao do 9430 pelo cargo Vendedor.');
    Assert.isFalse(
      vendBu,
      'O vendedor SOL NAO pode ter ' + CP_BU + ': so uma Restriction Rule vale por usuario.'
    );
  }

  @IsTest
  static void diretorSOLVeTarefasDaBUSOLENaoAsDeOutraBU() {
    Set<String> vistas = visiveisPara('soldir');
    Assert.isTrue(
      vistas.contains(PREFIXO + ' SOL do vendedor'),
      'O diretor SOL tem de ver a tarefa do vendedor SOL (regra por BU, nao por dono). Vistas: ' + vistas
    );
    Assert.isFalse(
      vistas.contains(PREFIXO + ' ADV contato Robson'),
      'O diretor SOL nao pode ver a tarefa ADV. Vistas: ' + vistas
    );
  }

  // ============================================================ F4: carimbo

  private static Id rtOpp(String dev) {
    return Schema.SObjectType.Opportunity.getRecordTypeInfosByDeveloperName().get(dev).getRecordTypeId();
  }

  private static Id novaOpp(String rt, String etapa, Id dono) {
    Account c = [SELECT Id FROM Account WHERE Name = :(PREFIXO + ' Robson Teste Ltda') LIMIT 1];
    Opportunity o = new Opportunity(
      Name = PREFIXO + ' Opp ' + rt,
      AccountId = c.Id,
      OwnerId = dono,
      RecordTypeId = rtOpp(rt),
      StageName = etapa,
      CloseDate = Date.today().addDays(30)
    );
    insert o;
    return o.Id;
  }

  private static Id novoLeadSOL() {
    Lead l = new Lead(
      LastName = PREFIXO + ' Lead SOL',
      Company = PREFIXO + ' Empresa SOL',
      RecordTypeId = Schema.SObjectType.Lead.getRecordTypeInfosByDeveloperName().get('SOL').getRecordTypeId(),
      Status = [SELECT ApiName FROM LeadStatus WHERE IsDefault = TRUE LIMIT 1].ApiName
    );
    l.put('CNPJ__c', '11222333000181');
    insert l;
    return l.Id;
  }

  /**
   * Le o campo como o Diretor Global de teste: o campo so tem FLS de leitura
   * via o PS da BU (nem o admin o enxerga, por design), e o Diretor
   * Global nao e restringido em atividades.
   */
  private static String buDe(Id atividadeId) {
    String o = atividadeId.getSObjectType() == Task.SObjectType ? 'Task' : 'Event';
    SObject r;
    System.runAs(usuario('global')) {
      r = Database.query('SELECT BU_Atividade__c FROM ' + o + ' WHERE Id = \'' + atividadeId + '\'');
    }
    return (String) r.get('BU_Atividade__c');
  }

  private static Task tarefa(String assunto, Id dono, Id whoId, Id whatId) {
    return new Task(
      Subject = PREFIXO + ' ' + assunto,
      OwnerId = dono,
      WhoId = whoId,
      WhatId = whatId,
      Status = 'Open',
      Priority = 'Normal'
    );
  }

  @IsTest
  static void carimboPeloDonoQuandoNaoHaLeadNemOpp() {
    Task t = [SELECT Id FROM Task WHERE Subject = :(PREFIXO + ' ADV contato Robson')];
    Assert.areEqual('ADV', buDe(t.Id), 'Sem Lead nem Opp, a BU vem do Department do dono (ADV).');
  }

  @IsTest
  static void carimboPelaOportunidadeTemPrecedenciaSobreODono() {
    Id oppAdv = novaOpp('ADV', 'Oportunidade Recebida', usuario('advat').Id);
    Id oppTel = novaOpp('STE_Telecom', 'Verificação de Antecedentes', usuario('advat').Id);
    // Dono SOL de proposito: a Opp manda, nao o Department do dono.
    Task tAdv = tarefa('na opp ADV', usuario('solvend').Id, null, oppAdv);
    Task tTel = tarefa('na opp Telecom', usuario('solvend').Id, null, oppTel);
    Test.startTest();
    insert new List<Task>{ tAdv, tTel };
    Test.stopTest();
    Assert.areEqual('ADV', buDe(tAdv.Id), 'WhatId Opp ADV carimba ADV.');
    Assert.areEqual('STE', buDe(tTel.Id), 'WhatId Opp Stech Telecom carimba STE.');
  }

  @IsTest
  static void carimboPeloLeadQuandoNaoHaOpp() {
    Id leadSol = novoLeadSOL();
    Task t = tarefa('no lead SOL', usuario('advat').Id, leadSol, null);
    Test.startTest();
    insert t;
    Test.stopTest();
    Assert.areEqual('SOL', buDe(t.Id), 'WhoId Lead SOL carimba SOL mesmo com dono ADV.');
  }

  @IsTest
  static void semBUOCampoFicaVazio() {
    Task t = tarefa('sem BU', usuario('global').Id, null, null);
    Test.startTest();
    insert t;
    Test.stopTest();
    Assert.isNull(buDe(t.Id), 'Dono sem Department de BU e sem Lead/Opp: campo vazio.');
  }

  @IsTest
  static void trocaDeWhatIdRecarimba() {
    Task t = [SELECT Id FROM Task WHERE Subject = :(PREFIXO + ' ADV contato Robson')];
    Id oppSol = novaOpp('SOL', 'Diagnóstico', usuario('solvend').Id);
    Test.startTest();
    update new Task(Id = t.Id, WhatId = oppSol);
    Test.stopTest();
    Assert.areEqual('SOL', buDe(t.Id), 'Ao trocar o WhatId para uma Opp SOL a BU e recalculada.');
  }

  @IsTest
  static void eventoECarimbadoERestritoPorBU() {
    Contact robson = [SELECT Id FROM Contact WHERE LastName = :(PREFIXO + ' Robson')];
    Event e = new Event(
      Subject = PREFIXO + ' evento ADV',
      OwnerId = usuario('advat').Id,
      WhoId = robson.Id,
      StartDateTime = System.now().addDays(1),
      EndDateTime = System.now().addDays(1).addHours(1)
    );
    insert e;
    Assert.areEqual('ADV', buDe(e.Id), 'Evento do dono ADV no Contato Robson carimba ADV.');
    Integer ste;
    Integer adv;
    Integer semCp;
    Integer vendOutro;
    Integer vendDono;
    String q = 'SELECT Id FROM Event WHERE Id = \'' + e.Id + '\'';
    System.runAs(usuario('steat')) {
      ste = Database.query(q, AccessLevel.USER_MODE).size();
    }
    System.runAs(usuario('advdir')) {
      adv = Database.query(q, AccessLevel.USER_MODE).size();
    }
    System.runAs(usuario('semcp')) {
      semCp = Database.query(q, AccessLevel.USER_MODE).size();
    }
    System.runAs(usuario('solvend')) {
      vendOutro = Database.query(q, AccessLevel.USER_MODE).size();
    }
    System.runAs(usuario('advat')) {
      vendDono = Database.query(q, AccessLevel.USER_MODE).size();
    }
    Assert.areEqual(0, ste, 'Acesso_BU_Eventos: o atendente STE nao ve o evento ADV.');
    Assert.areEqual(1, adv, 'O diretor ADV ve o evento ADV.');
    Assert.areEqual(1, semCp, 'Controle: sem a custom permission o evento continua visivel.');
    Assert.areEqual(0, vendOutro, 'Eventos_Somente_Do_Proprietario: o vendedor nao ve compromisso alheio.');
    Assert.areEqual(1, vendDono, 'O vendedor dono ve o proprio compromisso.');
  }

  @IsTest
  static void volume200TarefasCarimbadasEmUmDML() {
    Contact robson = [SELECT Id FROM Contact WHERE LastName = :(PREFIXO + ' Robson')];
    Id advat = usuario('advat').Id;
    List<Task> lote = new List<Task>();
    for (Integer i = 0; i < 200; i++) {
      lote.add(tarefa('lote ' + i, advat, robson.Id, null));
    }
    Test.startTest();
    insert lote;
    Integer soql = Limits.getQueries();
    Test.stopTest();
    Integer carimbadas = 0;
    System.runAs(usuario('global')) {
      for (Task t : (List<Task>) Database.query(
        'SELECT BU_Atividade__c FROM Task WHERE Subject LIKE \'' + PREFIXO + ' lote %\''
      )) {
        if (t.get('BU_Atividade__c') == 'ADV') {
          carimbadas++;
        }
      }
    }
    Assert.areEqual(200, carimbadas, 'As 200 tarefas do lote tem de sair carimbadas com ADV.');
    Assert.isTrue(soql < 50, 'O carimbo em lote nao pode consumir SOQL por registro. SOQL: ' + soql);
  }

  @IsTest
  static void vendedorSOLContinuaVendoSoAsProprias() {
    Set<String> vistas = visiveisPara('solvend');
    Assert.areEqual(
      new Set<String>{ PREFIXO + ' SOL do vendedor' },
      vistas,
      '9430 intacto: o vendedor SOL ve apenas a propria tarefa.'
    );
  }
}
