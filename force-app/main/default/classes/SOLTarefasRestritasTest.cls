/**
 * CLICKUP-9430 — Testes da Restriction Rule `SOL_Tarefas_Somente_Do_Proprietario`
 * e da custom permission `SOL_Restringir_Tarefas_Ao_Proprietario`.
 *
 * O que estes testes existem para provar, na mesma matriz de controle usada no
 * E2E real da org:
 *
 *   | usuário                 | caminho de acesso                  | enxerga  |
 *   |-------------------------|------------------------------------|----------|
 *   | COM a custom permission | SOQL em modo de usuário            | 1 (só a própria) |
 *   | SEM a custom permission | SOQL em modo de usuário            | 2 (controle)     |
 *   | COM a custom permission | classe `without sharing`, como a jornada | 2  |
 *   | COM a custom permission | AccessLevel.SYSTEM_MODE avulso     | 1 (contraprova)  |
 *
 * A terceira linha é a que protege a jornada SOL: toda a automação
 * (`SOLCadenciaContatoService`, `SOLDistribuicaoService`, `SOLNegocioPerdidoService`
 * e as demais) é `without sharing` e é acionada por Flow `RecordAfterSave`.
 *
 * A quarta linha foi MEDIDA, não presumida, e corrige uma leitura ingênua da
 * documentação. O guia diz "Restriction rules aren't applied for code executed
 * in System Mode", mas `AccessLevel.SYSTEM_MODE` sozinho não basta: ele dispensa
 * FLS e permissão de objeto, enquanto o acesso em nível de REGISTRO continua
 * seguindo a palavra-chave de sharing da classe chamadora. Quem levanta a regra
 * é o `without sharing` — por isso a jornada está protegida e por isso ninguém
 * deve tentar "consertar" um serviço trocando a cláusula do SOQL.
 *
 * A segunda linha é o CONTROLE que valida o próprio teste: se ela falhar (o
 * usuário sem a permissão também for restringido), a regra estaria incidindo
 * sobre quem não deveria — e as outras linhas perderiam o sentido.
 *
 * Nenhum teste usa SeeAllData: os dois usuários e as duas tarefas são criados
 * aqui. Nenhum teste depende de Id, perfil ou papel fixado no código.
 */
@IsTest
private class SOLTarefasRestritasTest {
  private static final String PERMISSAO = 'SOL_Restringir_Tarefas_Ao_Proprietario';
  private static final String PERMISSION_SET = 'PS_SOL_Comercial';
  private static final String PERFIL_SEM_VIEW_ALL = 'Standard User';

  private static final String ASSUNTO_PROPRIA = 'E2E_9430 tarefa do restrito';
  private static final String ASSUNTO_ALHEIA = 'E2E_9430 tarefa de terceiro';

  // ============================================================ semeadura

  @TestSetup
  static void semear() {
    Profile padrao = [
      SELECT Id
      FROM Profile
      WHERE Name = :PERFIL_SEM_VIEW_ALL
      LIMIT 1
    ];

    List<User> usuarios = new List<User>{
      montarUsuario(padrao.Id, 'restrito'),
      montarUsuario(padrao.Id, 'livre')
    };
    insert usuarios;

    // Só o primeiro recebe a permissão. O segundo é o controle.
    PermissionSet ps = [
      SELECT Id
      FROM PermissionSet
      WHERE Name = :PERMISSION_SET
      LIMIT 1
    ];
    insert new PermissionSetAssignment(
      AssigneeId = usuarios[0].Id,
      PermissionSetId = ps.Id
    );

    // DML de objeto não-setup precisa sair do mesmo contexto do DML de setup.
    System.runAs(new User(Id = UserInfo.getUserId())) {
      // As duas tarefas penduram no MESMO Contato de uma Conta. É esse o
      // caminho do vazamento real que o card bloqueia: Account tem OWD
      // pública (Edit) e Contact é ControlledByParent, então a atividade
      // filha fica visível para qualquer usuário interno. Sem esse pai
      // compartilhado as tarefas seriam órfãs, invisíveis entre usuários por
      // sharing comum — e o teste não distinguiria a Restriction Rule de
      // simples ausência de acesso.
      Account conta = new Account(Name = 'E2E_9430 Conta publica');
      insert conta;
      Contact contato = new Contact(
        LastName = 'E2E_9430 Contato publico',
        AccountId = conta.Id
      );
      insert contato;

      insert new List<Task>{
        new Task(
          Subject = ASSUNTO_PROPRIA,
          OwnerId = usuarios[0].Id,
          WhoId = contato.Id,
          Status = 'Open',
          Priority = 'Normal'
        ),
        new Task(
          Subject = ASSUNTO_ALHEIA,
          OwnerId = usuarios[1].Id,
          WhoId = contato.Id,
          Status = 'Open',
          Priority = 'Normal'
        )
      };
    }
  }

  // ============================================================ helpers

  private static User montarUsuario(Id perfilId, String apelido) {
    String unico =
      String.valueOf(Math.abs(Crypto.getRandomInteger())) + apelido;
    return new User(
      FirstName = 'RR',
      LastName = 'Teste ' + apelido,
      Alias = ('rr' + apelido).left(8),
      Email = 'rr.' + apelido + '@arnone.invalid',
      Username = 'rr.' + unico + '@arnone.clickup9430.test.invalid',
      ProfileId = perfilId,
      TimeZoneSidKey = 'America/Sao_Paulo',
      LocaleSidKey = 'pt_BR',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'pt_BR',
      IsActive = true
    );
  }

  private static User buscarUsuario(String apelido) {
    return [
      SELECT Id, Name
      FROM User
      WHERE LastName = :('Teste ' + apelido)
      LIMIT 1
    ];
  }

  /** Consulta as tarefas do cenário no modo de acesso pedido. */
  private static List<Task> tarefasDoCenario(AccessLevel modo) {
    return Database.query(
      'SELECT Id, Subject, OwnerId FROM Task ' +
      'WHERE Subject LIKE \'E2E_9430%\' ORDER BY Subject',
      modo
    );
  }

  /**
   * Reproduz a topologia real da jornada: Flow RecordAfterSave chama um
   * Invocable, que chama uma classe de serviço `without sharing` com SOQL sem
   * cláusula de modo. É assim que estão `SOLCadenciaContatoService`,
   * `SOLDistribuicaoService`, `SOLNegocioPerdidoService` e as outras sete.
   * Sem declarar o `sharing` igual ao delas o teste mediria outra coisa.
   */
  private without sharing class ServicoComoNaJornada {
    List<Task> consultar() {
      return [
        SELECT Id, Subject, OwnerId
        FROM Task
        WHERE Subject LIKE 'E2E_9430%'
        ORDER BY Subject
      ];
    }
  }

  // ============================================================ testes

  @IsTest
  static void permissaoChegaPeloPermissionSetEApenasAli() {
    User restrito = buscarUsuario('restrito');
    User livre = buscarUsuario('livre');

    Boolean temRestrito;
    Boolean temLivre;

    System.runAs(restrito) {
      temRestrito = FeatureManagement.checkPermission(PERMISSAO);
    }
    System.runAs(livre) {
      temLivre = FeatureManagement.checkPermission(PERMISSAO);
    }

    Assert.isTrue(
      temRestrito,
      'O vendedor restrito deveria receber ' +
        PERMISSAO +
        ' pelo permission set ' +
        PERMISSION_SET +
        '. Sem ela a Restriction Rule não incide e o vazamento volta.'
    );
    Assert.isFalse(
      temLivre,
      'Quem não tem o permission set NÃO pode receber ' +
        PERMISSAO +
        ': a regra ficaria incidindo sobre usuários fora do escopo do card.'
    );
  }

  @IsTest
  static void modoDeUsuarioRestringeAoProprietario() {
    User restrito = buscarUsuario('restrito');

    List<Task> vistas;
    System.runAs(restrito) {
      vistas = tarefasDoCenario(AccessLevel.USER_MODE);
    }

    Assert.areEqual(
      1,
      vistas.size(),
      'Em modo de usuário o vendedor restrito deve enxergar apenas a própria ' +
        'tarefa. Vistas: ' +
        vistas
    );
    Assert.areEqual(
      ASSUNTO_PROPRIA,
      vistas[0].Subject,
      'A única tarefa visível tem de ser a do próprio proprietário.'
    );
    Assert.areEqual(
      restrito.Id,
      vistas[0].OwnerId,
      'O proprietário da tarefa visível tem de ser o próprio usuário restrito.'
    );
  }

  @IsTest
  static void usuarioSemAPermissaoNaoEhRestringido() {
    User livre = buscarUsuario('livre');

    List<Task> vistas;
    System.runAs(livre) {
      vistas = tarefasDoCenario(AccessLevel.USER_MODE);
    }

    // CONTROLE. Se esta asserção falhar, a regra está incidindo sobre quem não
    // tem a permissão — e os outros dois testes deixam de significar algo.
    Assert.areEqual(
      2,
      vistas.size(),
      'Usuário SEM a custom permission não pode ser afetado pela Restriction ' +
        'Rule. Se enxergou menos de 2, a regra está incidindo indevidamente. ' +
        'Vistas: ' +
        vistas
    );
  }

  @IsTest
  static void jornadaWithoutSharingEnxergaTudoESystemModeSozinhoNao() {
    User restrito = buscarUsuario('restrito');

    List<Task> vistas;
    List<Task> viaServico;
    System.runAs(restrito) {
      vistas = tarefasDoCenario(AccessLevel.SYSTEM_MODE);
      viaServico = new ServicoComoNaJornada().consultar();
    }

    // O que de fato protege a jornada é a segunda: uma classe `without sharing`
    // com SOQL sem cláusula, exatamente como os serviços SOL.
    Assert.areEqual(
      2,
      viaServico.size(),
      'Uma classe `without sharing` com SOQL sem cláusula — a forma exata dos ' +
        'serviços da jornada SOL — precisa continuar enxergando as tarefas de ' +
        'todos os vendedores. Se este número cair, a régua de 3 tentativas, o ' +
        'cancelamento por contato efetivado e a reatribuição passam a contar ' +
        'errado para Leads que trocaram de dono. Vistas: ' +
        viaServico
    );

    // Contraprova deliberada, e o motivo de ela existir: `AccessLevel.SYSTEM_MODE`
    // sozinho NÃO levanta a Restriction Rule. Ele dispensa FLS e permissão de
    // objeto; o acesso em nível de REGISTRO continua seguindo a palavra-chave de
    // sharing da classe chamadora — e esta classe de teste não declara nenhuma.
    // Fica registrado para que ninguém tente "consertar" um serviço da jornada
    // trocando a cláusula do SOQL: o que protege é o `without sharing`.
    Assert.areEqual(
      1,
      vistas.size(),
      'AccessLevel.SYSTEM_MODE partindo de classe sem declaração de sharing ' +
        'NÃO deve escapar da Restriction Rule. Se este número virar 2, a ' +
        'semântica da plataforma mudou e a nota acima precisa ser revista. ' +
        'Vistas: ' +
        vistas
    );
  }

  @IsTest
  static void vendedorRestritoContinuaMexendoNasProprias() {
    User restrito = buscarUsuario('restrito');
    Task propria = [
      SELECT Id, Status
      FROM Task
      WHERE Subject = :ASSUNTO_PROPRIA
      LIMIT 1
    ];

    Task criada = new Task(
      Subject = 'E2E_9430 criada pelo restrito',
      OwnerId = restrito.Id,
      Status = 'Open',
      Priority = 'Normal'
    );

    System.runAs(restrito) {
      Test.startTest();
      insert criada;
      update new Task(Id = propria.Id, Status = 'Completed');
      Test.stopTest();
    }

    Assert.areEqual(
      'Completed',
      [SELECT Status FROM Task WHERE Id = :propria.Id].Status,
      'O vendedor restrito tem de continuar concluindo as próprias tarefas.'
    );
    Assert.isNotNull(
      criada.Id,
      'O vendedor restrito tem de continuar criando tarefas próprias.'
    );
  }
}