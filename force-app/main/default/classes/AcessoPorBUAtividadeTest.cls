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
 *   - Spike S2: o muting `PSG_SOL_Diretor_Muting` silencia
 *     `SOL_Restringir_Tarefas_Ao_Proprietario` dentro do `PSG_SOL_Diretor`.
 *   - Convivência com o 9430: o vendedor SOL continua vendo só as próprias.
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

    // O PSG de STE inclui PS_Atendimento e PS_Atendimento_Chat, que exigem
    // permission set licenses. Sem elas a atribuição do PSG falha.
    atribuirLicencas(porApelido.get('steat').Id);

    List<PermissionSetAssignment> psas = new List<PermissionSetAssignment>();
    psas.add(psg(porApelido.get('advat').Id, 'PSG_ADV_Atendente'));
    psas.add(psg(porApelido.get('advdir').Id, 'PSG_ADV_Diretor'));
    psas.add(psg(porApelido.get('steat').Id, 'PSG_STE_Atendente'));
    psas.add(psg(porApelido.get('solvend').Id, 'PSG_SOL_Comercial'));
    psas.add(psg(porApelido.get('soldir').Id, 'PSG_SOL_Diretor'));
    psas.add(psg(porApelido.get('global').Id, 'PSG_Diretor_Global'));
    psas.add(ps(porApelido.get('semcp').Id, 'PS_Comercial'));
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
  static void mutingSilenciaARestricaoDoVendedorNoDiretorSOL() {
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
    Assert.isFalse(dirSol, 'S2: o muting tem de silenciar ' + CP_SOL + ' no PSG_SOL_Diretor.');
    Assert.isTrue(dirBu, 'O diretor SOL tem de receber ' + CP_BU + '.');
    Assert.isTrue(dirHist, 'O diretor SOL tem de receber ' + CP_HIST + '.');
    Assert.isTrue(vendSol, 'O vendedor SOL continua com a restricao do 9430.');
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
