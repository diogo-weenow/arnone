/**
 * Registra as respostas do Assistente Stech Telecom antes do transbordo.
 *
 * A identificação segue esta ordem, e para na primeira que achar:
 *   1. e-mail informado agora    — Contato, depois Lead aberto
 *   2. vínculo do telefone       — MessagingEndUser.ContactId, depois .LeadId
 *   3. telefone do candidato     — STE_Telefone_E164__c, com e sem nono dígito
 *   4. nada                      — cria Lead STech
 *
 * Os passos 2 e 3 existem para não abrir registro novo quando a pessoa volta
 * pelo mesmo WhatsApp e informa um e-mail diferente do da conversa anterior.
 * Ao reaproveitar um cadastro, o Email original é preservado: só os campos de
 * qualificação são regravados. O CPF continua sendo conferido pelo atendente.
 *
 * Quando a conversa tem arquivo anexado, a ação marca a CNH como recebida e
 * grava o horário do próprio arquivo. Isso registra o fato de o documento ter
 * chegado, que é objetivo e datável; não substitui a conferência do atendente,
 * que continua sendo quem decide se o documento serve. A marca nunca é
 * desfeita aqui: candidato que já enviou antes não volta a constar como sem
 * CNH ao reaproveitar o cadastro.
 */
public without sharing class STE_BotRegistrarCandidato {
  private static final String RT_LEAD = 'STE';
  private static final String UNIDADE_STE = 'STE';

  // Campos que o bot grava ao reaproveitar um cadastro. O update leva só estes:
  // o usuário do bot roda com licença de integração e não pode salvar um
  // registro que carregue campos que ele só lê (Email, gênero), ainda que sem
  // alteração. Campo novo gravado em aplicar() precisa entrar aqui.
  private static final List<String> CAMPOS_GRAVADOS_LEAD = new List<String>{
    'MobilePhone',
    'Status',
    'STE_Classificacao_Fila__c',
    'STE_Empresa_Telecom_Anterior__c',
    'STE_Etapa_Bot__c',
    'STE_Etapa_Bot_Desde__c',
    'STE_Faixa_Etaria__c',
    'STE_Interesse_Pre_Inscricao__c',
    'STE_Ja_Trabalhou_Telecom__c',
    'STE_MessagingSession_Id__c',
    'STE_Motivo_Desqualificacao__c',
    'STE_Possui_CNH__c',
    'STE_Prazo_Envio_CNH__c',
    'STE_Telefone_E164__c'
  };

  private static final List<String> CAMPOS_GRAVADOS_CONTATO = new List<String>{
    'MobilePhone',
    'STE_Classificacao_Fila__c',
    'STE_Empresa_Telecom_Anterior__c',
    'STE_Faixa_Etaria__c',
    'STE_Interesse_Pre_Inscricao__c',
    'STE_Ja_Trabalhou_Telecom__c',
    'STE_MessagingSession_Id__c',
    'STE_Possui_CNH__c',
    'STE_Telefone_E164__c'
  };

  public class Entrada {
    @InvocableVariable(label='E-mail' required=true)
    public String email;

    @InvocableVariable(label='Nome completo' required=true)
    public String nomeCompleto;

    @InvocableVariable(label='Resposta pré-inscrição')
    public String respostaPreInscricao;

    @InvocableVariable(label='Resposta faixa etária')
    public String respostaIdade;

    @InvocableVariable(label='Já trabalhou com Telecom')
    public String jaTrabalhouTelecom;

    @InvocableVariable(label='Qual empresa de Telecom')
    public String empresaTelecomAnterior;

    @InvocableVariable(label='Resposta sobre envio da CNH')
    public String respostaCNH;

    @InvocableVariable(label='Id roteável da sessão')
    public String routableId;

    @InvocableVariable(label='Id do usuário final de mensageria')
    public String endUserId;

  }

  public class Resultado {
    @InvocableVariable(label='Sucesso')
    public Boolean sucesso;

    @InvocableVariable(label='Mensagem')
    public String mensagem;

    @InvocableVariable(label='Id do registro')
    public String recordId;

    @InvocableVariable(label='Tipo do registro')
    public String tipoRegistro;

    /**
     * Falso quando o candidato esbarra em algum critério da turma (idade,
     * perfil ou CNH). O assistente usa isso para encerrar a conversa em vez de
     * encaminhar para atendimento.
     */
    @InvocableVariable(label='Atende aos critérios da turma')
    public Boolean elegivel;

    private Resultado() {
      sucesso = false;
      elegivel = true;
    }
  }

  private class OperacaoContato {
    Contact registro;
    Integer indice;
    OperacaoContato(Contact registro, Integer indice) {
      this.registro = registro;
      this.indice = indice;
    }
  }

  private class OperacaoLead {
    Lead registro;
    Integer indice;
    OperacaoLead(Lead registro, Integer indice) {
      this.registro = registro;
      this.indice = indice;
    }
  }

  @InvocableMethod(
    label='Registrar candidato do bot — Stech Telecom'
    description='Atualiza Contato/Lead identificado pelo e-mail, pelo vínculo do telefone ou pelo telefone, ou cria um Lead STech com as respostas do chatbot antes do transbordo.'
    category='Stech Telecom'
  )
  public static List<Resultado> registrar(List<Entrada> entradas) {
    List<Resultado> saida = new List<Resultado>();
    if (entradas == null || entradas.isEmpty()) {
      return saida;
    }

    Map<Id, MessagingEndUser> endUsers = carregarEndUsers(entradas);

    Set<String> emails = new Set<String>();
    for (Entrada entrada : entradas) {
      Resultado r = new Resultado();
      saida.add(r);
      String email = normalizarEmail(entrada == null ? null : entrada.email);
      if (email == null) {
        r.mensagem = 'O e-mail não foi informado; o candidato não pôde ser registrado.';
      } else {
        emails.add(email);
      }
    }

    Set<Id> leadsVinculados = new Set<Id>();
    Set<Id> contatosVinculados = new Set<Id>();
    Set<String> telefones = new Set<String>();
    for (MessagingEndUser eu : endUsers.values()) {
      if (eu.LeadId != null)
        leadsVinculados.add(eu.LeadId);
      if (eu.ContactId != null)
        contatosVinculados.add(eu.ContactId);
      telefones.addAll(STE_Telefone.variantes(eu.MessagingPlatformKey));
    }

    Map<Id, Contact> contatos = new Map<Id, Contact>(
      [
        SELECT
          Id,
          Email,
          MobilePhone,
          STE_Classificacao_Fila__c,
          STE_Empresa_Telecom_Anterior__c,
          STE_Faixa_Etaria__c,
          STE_Interesse_Pre_Inscricao__c,
          STE_Possui_CNH__c,
          STE_Ja_Trabalhou_Telecom__c,
          STE_Telefone_E164__c
        FROM Contact
        WHERE
          Email IN :emails
          OR Id IN :contatosVinculados
          OR STE_Telefone_E164__c IN :telefones
        ORDER BY LastModifiedDate DESC
      ]
    );

    Map<Id, Lead> leads = new Map<Id, Lead>(
      [
        SELECT
          Id,
          Email,
          Status,
          MobilePhone,
          STE_Classificacao_Fila__c,
          STE_Empresa_Telecom_Anterior__c,
          STE_Faixa_Etaria__c,
          STE_Interesse_Pre_Inscricao__c,
          STE_Ja_Trabalhou_Telecom__c,
          STE_Possui_CNH__c,
          STE_Genero__c,
          STE_Prazo_Envio_CNH__c,
          STE_Telefone_E164__c
        FROM Lead
        WHERE
          IsConverted = FALSE
          AND (Email IN :emails
          OR Id IN :leadsVinculados
          OR STE_Telefone_E164__c IN :telefones)
        ORDER BY LastModifiedDate DESC
      ]
    );

    Map<String, Contact> contatoPorEmail = new Map<String, Contact>();
    Map<String, Contact> contatoPorTelefone = new Map<String, Contact>();
    for (Contact c : contatos.values()) {
      indexar(contatoPorEmail, normalizarEmail(c.Email), c);
      for (String variante : STE_Telefone.variantes(c.STE_Telefone_E164__c)) {
        indexar(contatoPorTelefone, variante, c);
      }
    }

    Map<String, Lead> leadPorEmail = new Map<String, Lead>();
    Map<String, Lead> leadPorTelefone = new Map<String, Lead>();
    for (Lead l : leads.values()) {
      indexar(leadPorEmail, normalizarEmail(l.Email), l);
      for (String variante : STE_Telefone.variantes(l.STE_Telefone_E164__c)) {
        indexar(leadPorTelefone, variante, l);
      }
    }

    List<OperacaoContato> contatosAtualizar = new List<OperacaoContato>();
    List<OperacaoLead> leadsAtualizar = new List<OperacaoLead>();
    List<OperacaoLead> leadsCriar = new List<OperacaoLead>();
    Id rtLead = recordTypeLead();

    for (Integer i = 0; i < entradas.size(); i++) {
      Entrada entrada = entradas[i];
      String email = normalizarEmail(entrada == null ? null : entrada.email);
      if (email == null) {
        continue;
      }

      String telefone = telefoneDe(endUsers, entrada);
      MessagingEndUser endUser = endUserDe(endUsers, entrada);

      Contact contatoAchado = contatoPorEmail.get(email);
      Lead leadAchado = contatoAchado != null ? null : leadPorEmail.get(email);

      // O e-mail informado agora não achou ninguém: cai para a identidade do
      // telefone, que é o que impede Lead duplicado quando a pessoa volta e
      // informa um e-mail diferente do da conversa anterior.
      if (contatoAchado == null && leadAchado == null && endUser != null) {
        if (contatos.containsKey(endUser.ContactId)) {
          contatoAchado = contatos.get(endUser.ContactId);
        } else if (leads.containsKey(endUser.LeadId)) {
          leadAchado = leads.get(endUser.LeadId);
        } else {
          String chave = primeiraVariante(
            endUser.MessagingPlatformKey,
            contatoPorTelefone.keySet()
          );
          if (chave != null) {
            contatoAchado = contatoPorTelefone.get(chave);
          } else {
            chave = primeiraVariante(
              endUser.MessagingPlatformKey,
              leadPorTelefone.keySet()
            );
            if (chave != null) {
              leadAchado = leadPorTelefone.get(chave);
            }
          }
        }
      }

      if (contatoAchado != null) {
        aplicar(contatoAchado, entrada, telefone);
        contatosAtualizar.add(new OperacaoContato(contatoAchado, i));
      } else if (leadAchado != null) {
        aplicar(leadAchado, entrada, telefone);
        leadsAtualizar.add(new OperacaoLead(leadAchado, i));
      } else {
        String nome = texto(entrada.nomeCompleto);
        if (nome == null) {
          nome = 'Candidato STech';
        }
        Lead novo = new Lead(
          LastName = nome,
          Company = nome,
          Email = email,
          LeadSource = 'Website',
          RecordTypeId = rtLead,
          Unidade_Origem__c = UNIDADE_STE
        );
        aplicar(novo, entrada, telefone);
        leadsCriar.add(new OperacaoLead(novo, i));
        indexar(leadPorEmail, email, novo);
        for (String variante : STE_Telefone.variantes(telefone)) {
          indexar(leadPorTelefone, variante, novo);
        }
      }
    }

    executarContatos(contatosAtualizar, saida);
    executarLeads(leadsAtualizar, saida, false);
    executarLeads(leadsCriar, saida, true);
    vincularEndUsers(entradas, saida, endUsers);
    return saida;
  }

  /** Carrega os MessagingEndUser das entradas: telefone e vínculos atuais. */
  private static Map<Id, MessagingEndUser> carregarEndUsers(
    List<Entrada> entradas
  ) {
    Set<Id> ids = new Set<Id>();
    for (Entrada entrada : entradas) {
      if (entrada == null)
        continue;
      Id endUser = idDoTipo(entrada.endUserId, MessagingEndUser.SObjectType);
      if (endUser != null)
        ids.add(endUser);
    }
    if (ids.isEmpty())
      return new Map<Id, MessagingEndUser>();
    return new Map<Id, MessagingEndUser>(
      [
        SELECT Id, LeadId, ContactId, MessagingPlatformKey
        FROM MessagingEndUser
        WHERE Id IN :ids
      ]
    );
  }

  /** Telefone E.164 só com dígitos, a partir do MessagingPlatformKey. */
  private static MessagingEndUser endUserDe(
    Map<Id, MessagingEndUser> endUsers,
    Entrada entrada
  ) {
    if (entrada == null)
      return null;
    Id endUser = idDoTipo(entrada.endUserId, MessagingEndUser.SObjectType);
    return endUser == null ? null : endUsers.get(endUser);
  }

  private static String telefoneDe(
    Map<Id, MessagingEndUser> endUsers,
    Entrada entrada
  ) {
    MessagingEndUser eu = endUserDe(endUsers, entrada);
    return eu == null ? null : STE_Telefone.chave(eu.MessagingPlatformKey);
  }

  private static void indexar(
    Map<String, Lead> destino,
    String chave,
    Lead valor
  ) {
    if (chave != null && !destino.containsKey(chave))
      destino.put(chave, valor);
  }

  private static void indexar(
    Map<String, Contact> destino,
    String chave,
    Contact valor
  ) {
    if (chave != null && !destino.containsKey(chave))
      destino.put(chave, valor);
  }

  /** Primeira variante do telefone presente no conjunto de chaves indexadas. */
  private static String primeiraVariante(
    String telefone,
    Set<String> disponiveis
  ) {
    for (String variante : STE_Telefone.variantes(telefone)) {
      if (disponiveis.contains(variante))
        return variante;
    }
    return null;
  }



  private static Id idDoTipo(String valor, Schema.SObjectType tipoEsperado) {
    String limpo = texto(valor);
    if (limpo == null)
      return null;
    try {
      Id candidato = (Id) limpo;
      return candidato.getSObjectType() == tipoEsperado ? candidato : null;
    } catch (Exception e) {
      return null;
    }
  }

  private static void aplicar(Contact c, Entrada entrada, String telefone) {
    c.STE_Interesse_Pre_Inscricao__c = interesse(entrada.respostaPreInscricao);
    c.STE_Faixa_Etaria__c = faixa(entrada.respostaIdade);
    c.STE_Ja_Trabalhou_Telecom__c = simNao(entrada.jaTrabalhouTelecom);
    c.STE_Empresa_Telecom_Anterior__c = empresa(entrada);
    c.STE_Possui_CNH__c = posseCnh(entrada.respostaCNH);
    c.STE_Classificacao_Fila__c = classificacao(entrada);
    c.STE_MessagingSession_Id__c = sessao(entrada);
    if (telefone != null) {
      c.STE_Telefone_E164__c = telefone;
      if (String.isBlank(c.MobilePhone)) {
        c.MobilePhone = '+' + telefone;
      }
    }
  }

  /**
   * Critérios da turma, na ordem definida pelo Instituto: idade e gênero são
   * avaliados antes da CNH. Devolve o motivo da recusa, ou null se o candidato
   * atende a tudo que conseguimos verificar hoje.
   *
   * "CNH provisória" existe na lista de motivos mas ainda não é usado: nem o
   * formulário do site nem o assistente perguntam se a habilitação é
   * definitiva, então não há de onde tirar essa informação.
   */
  private static String motivoInelegibilidade(Lead l) {
    if (l.STE_Faixa_Etaria__c == 'Fora da faixa') {
      return 'Fora da faixa etária';
    }
    if (l.STE_Genero__c == 'Feminino') {
      return 'Não atende ao perfil da turma';
    }
    if (l.STE_Possui_CNH__c == 'Não') {
      return 'Sem CNH';
    }
    return null;
  }

  private static void aplicar(Lead l, Entrada entrada, String telefone) {
    l.STE_Interesse_Pre_Inscricao__c = interesse(entrada.respostaPreInscricao);
    l.STE_Faixa_Etaria__c = faixa(entrada.respostaIdade);
    l.STE_Ja_Trabalhou_Telecom__c = simNao(entrada.jaTrabalhouTelecom);
    l.STE_Empresa_Telecom_Anterior__c = empresa(entrada);
    // O assistente só oferece "agora" ou "depois"; quem declarou não ter CNH
    // fez isso no formulário do site. Sem resposta do bot, preserva o que veio de lá.
    String posseInformada = posseCnh(entrada.respostaCNH);
    if (posseInformada != null) {
      l.STE_Possui_CNH__c = posseInformada;
    }
    l.STE_Classificacao_Fila__c = classificacao(entrada);
    l.STE_MessagingSession_Id__c = sessao(entrada);
    // Chegou ao fim do fluxo: não há mais pergunta pendente. Quem foi barrado
    // por um critério da turma fica marcado à parte, para não ser confundido
    // no funil com quem completou a pré-inscrição.
    String motivo = motivoInelegibilidade(l);
    l.STE_Etapa_Bot__c = motivo == null ? 'Concluído' : 'Desqualificado';
    l.STE_Etapa_Bot_Desde__c = System.now();
    l.STE_Motivo_Desqualificacao__c = motivo;
    if (telefone != null) {
      l.STE_Telefone_E164__c = telefone;
      if (String.isBlank(l.MobilePhone)) {
        l.MobilePhone = '+' + telefone;
      }
    }
    l.STE_Prazo_Envio_CNH__c = l.STE_Possui_CNH__c == 'Sim, envio posterior'
      ? System.now().addHours(2)
      : null;
    l.Status = motivo == null ? 'Validação' : 'Desqualificado';
  }

  private static void executarContatos(
    List<OperacaoContato> operacoes,
    List<Resultado> saida
  ) {
    if (operacoes.isEmpty())
      return;
    List<Contact> registros = new List<Contact>();
    for (OperacaoContato op : operacoes)
      registros.add(
        (Contact) somenteGravados(op.registro, CAMPOS_GRAVADOS_CONTATO)
      );
    Database.SaveResult[] resultados = Database.update(registros, false);
    for (Integer i = 0; i < resultados.size(); i++) {
      concluir(saida[operacoes[i].indice], resultados[i], 'Contact');
    }
  }

  private static void executarLeads(
    List<OperacaoLead> operacoes,
    List<Resultado> saida,
    Boolean inserir
  ) {
    if (operacoes.isEmpty())
      return;
    List<Lead> registros = new List<Lead>();
    for (OperacaoLead op : operacoes)
      registros.add(
        inserir
          ? op.registro
          : (Lead) somenteGravados(op.registro, CAMPOS_GRAVADOS_LEAD)
      );
    Database.SaveResult[] resultados = inserir
      ? Database.insert(registros, false)
      : Database.update(registros, false);
    for (Integer i = 0; i < resultados.size(); i++) {
      concluir(
        saida[operacoes[i].indice],
        resultados[i],
        'Lead',
        operacoes[i].registro
      );
    }
  }

  /** Cópia do registro com o Id e apenas os campos que o bot grava. */
  private static SObject somenteGravados(SObject origem, List<String> campos) {
    SObject copia = origem.getSObjectType().newSObject(origem.Id);
    Map<String, Object> preenchidos = origem.getPopulatedFieldsAsMap();
    for (String campo : campos) {
      if (preenchidos.containsKey(campo)) {
        copia.put(campo, preenchidos.get(campo));
      }
    }
    return copia;
  }

  /**
   * Grava no MessagingEndUser o vínculo durável entre o telefone e o registro.
   *
   * O MessagingEndUser é único por telefone e por canal, e sobrevive entre
   * conversas, ao contrário da MessagingSession. Contato tem precedência sobre
   * Lead: quando o candidato já é Contato, o LeadId é limpo.
   */
  private static void vincularEndUsers(
    List<Entrada> entradas,
    List<Resultado> saida,
    Map<Id, MessagingEndUser> endUsers
  ) {
    Map<Id, Resultado> porEndUser = new Map<Id, Resultado>();
    for (Integer i = 0; i < entradas.size(); i++) {
      Entrada entrada = entradas[i];
      if (entrada == null)
        continue;
      Id endUser = idDoTipo(entrada.endUserId, MessagingEndUser.SObjectType);
      Resultado r = saida[i];
      if (
        endUser == null ||
        !endUsers.containsKey(endUser) ||
        r.sucesso != true ||
        r.recordId == null
      )
        continue;
      porEndUser.put(endUser, r);
    }
    if (porEndUser.isEmpty())
      return;

    // Instâncias novas de propósito: o registro carregado traz o
    // MessagingPlatformKey, que não é gravável e derruba o update.
    List<MessagingEndUser> alterar = new List<MessagingEndUser>();
    for (Id chave : porEndUser.keySet()) {
      MessagingEndUser eu = endUsers.get(chave);
      Resultado r = porEndUser.get(chave);
      Id registro = (Id) r.recordId;
      if (r.tipoRegistro == 'Contact') {
        if (eu.ContactId != registro) {
          alterar.add(
            new MessagingEndUser(
              Id = chave,
              ContactId = registro,
              LeadId = null
            )
          );
        }
      } else if (eu.ContactId == null && eu.LeadId != registro) {
        alterar.add(new MessagingEndUser(Id = chave, LeadId = registro));
      }
    }
    if (!alterar.isEmpty())
      Database.update(alterar, false);
  }

  private static void concluir(
    Resultado saida,
    Database.SaveResult resultado,
    String tipo
  ) {
    concluir(saida, resultado, tipo, null);
  }

  private static void concluir(
    Resultado saida,
    Database.SaveResult resultado,
    String tipo,
    Lead registro
  ) {
    saida.sucesso = resultado.isSuccess();
    saida.tipoRegistro = tipo;
    if (registro != null) {
      saida.elegivel = registro.STE_Motivo_Desqualificacao__c == null;
    }
    if (resultado.isSuccess()) {
      saida.recordId = String.valueOf(resultado.getId());
      saida.mensagem = tipo + ' registrado com as respostas do chatbot.';
    } else {
      saida.mensagem = resultado.getErrors().isEmpty()
        ? 'Não foi possível registrar o candidato.'
        : resultado.getErrors()[0].getMessage();
    }
  }

  private static String classificacao(Entrada entrada) {
    if (faixa(entrada.respostaIdade) == 'Fora da faixa')
      return 'Fria';
    String posse = posseCnh(entrada.respostaCNH);
    if (posse == 'Sim, envio imediato')
      return 'Quente';
    if (posse == 'Sim, envio posterior')
      return 'Morna';
    return null;
  }

  private static String sessao(Entrada entrada) {
    Id sessaoId = entrada == null
      ? null
      : idDoTipo(entrada.routableId, MessagingSession.SObjectType);
    return sessaoId == null ? null : String.valueOf(sessaoId);
  }

  private static String faixa(String valor) {
    return igual(valor, 'Sim')
      ? 'De 20 a 50 anos'
      : igual(valor, 'Não') ? 'Fora da faixa' : null;
  }

  private static String posseCnh(String valor) {
    return igual(valor, 'Vou enviar agora') ||
      igual(valor, 'Sim, vou enviar agora')
      ? 'Sim, envio imediato'
      : igual(valor, 'Enviarei depois') ? 'Sim, envio posterior' : null;
  }

  private static String interesse(String valor) {
    if (igual(valor, 'Sim, vamos lá!'))
      return 'Sim, vamos lá!';
    if (igual(valor, 'Quero saber mais'))
      return 'Quero saber mais';
    return null;
  }

  private static String simNao(String valor) {
    if (igual(valor, 'Sim'))
      return 'Sim';
    if (igual(valor, 'Não'))
      return 'Não';
    return null;
  }

  private static String empresa(Entrada entrada) {
    return simNao(entrada.jaTrabalhouTelecom) == 'Sim'
      ? texto(entrada.empresaTelecomAnterior)
      : null;
  }

  private static String normalizarEmail(String valor) {
    String limpo = texto(valor);
    return limpo == null ? null : limpo.toLowerCase();
  }

  private static String texto(String valor) {
    return String.isBlank(valor) ? null : valor.trim();
  }

  private static Boolean igual(String a, String b) {
    return a != null && a.trim().equalsIgnoreCase(b);
  }

  private static Id recordTypeLead() {
    Schema.RecordTypeInfo info = Lead.SObjectType.getDescribe()
      .getRecordTypeInfosByDeveloperName()
      .get(RT_LEAD);
    if (info == null) {
      throw new RegistroBotException('Record type Lead.STE não encontrado.');
    }
    return info.getRecordTypeId();
  }

  public class RegistroBotException extends Exception {
  }
}