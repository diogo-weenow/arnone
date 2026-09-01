/**
 * Registra as respostas do Assistente Stech Telecom antes do transbordo.
 *
 * A identificação nesta etapa é o e-mail, pois CPF e CNH são conferidos pelo
 * atendente. Um Contato existente é atualizado; caso contrário, um Lead STech
 * aberto é atualizado ou criado. A ação nunca marca a CNH como recebida.
 */
public without sharing class STE_BotRegistrarCandidato {
  private static final String RT_LEAD = 'STE';
  private static final String UNIDADE_STE = 'STE';

  @TestVisible
  private static Set<Id> sessoesComAnexoTeste;

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

    private Resultado() {
      sucesso = false;
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
    description='Atualiza Contato/Lead pelo e-mail ou cria um Lead STech com as respostas do chatbot antes do transbordo.'
    category='Stech Telecom'
  )
  public static List<Resultado> registrar(List<Entrada> entradas) {
    List<Resultado> saida = new List<Resultado>();
    if (entradas == null || entradas.isEmpty()) {
      return saida;
    }

    preencherRespostaCnhPorAnexo(entradas);

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

    Map<String, Contact> contatoPorEmail = new Map<String, Contact>();
    for (Contact c : [
      SELECT
        Id,
        Email,
        STE_Classificacao_Fila__c,
        STE_Empresa_Telecom_Anterior__c,
        STE_Faixa_Etaria__c,
        STE_Interesse_Pre_Inscricao__c,
        STE_Ja_Trabalhou_Telecom__c,
        STE_Possui_CNH__c
      FROM Contact
      WHERE Email IN :emails
      ORDER BY LastModifiedDate DESC
    ]) {
      String chave = normalizarEmail(c.Email);
      if (!contatoPorEmail.containsKey(chave)) {
        contatoPorEmail.put(chave, c);
      }
    }

    Map<String, Lead> leadPorEmail = new Map<String, Lead>();
    for (Lead l : [
      SELECT
        Id,
        Email,
        Status,
        STE_Classificacao_Fila__c,
        STE_Empresa_Telecom_Anterior__c,
        STE_Faixa_Etaria__c,
        STE_Interesse_Pre_Inscricao__c,
        STE_Ja_Trabalhou_Telecom__c,
        STE_Possui_CNH__c,
        STE_Prazo_Envio_CNH__c
      FROM Lead
      WHERE Email IN :emails AND IsConverted = FALSE
      ORDER BY LastModifiedDate DESC
    ]) {
      String chave = normalizarEmail(l.Email);
      if (!leadPorEmail.containsKey(chave)) {
        leadPorEmail.put(chave, l);
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

      if (contatoPorEmail.containsKey(email)) {
        Contact c = contatoPorEmail.get(email);
        aplicar(c, entrada);
        contatosAtualizar.add(new OperacaoContato(c, i));
      } else if (leadPorEmail.containsKey(email)) {
        Lead l = leadPorEmail.get(email);
        aplicar(l, entrada);
        leadsAtualizar.add(new OperacaoLead(l, i));
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
        aplicar(novo, entrada);
        leadsCriar.add(new OperacaoLead(novo, i));
        leadPorEmail.put(email, novo);
      }
    }

    executarContatos(contatosAtualizar, saida);
    executarLeads(leadsAtualizar, saida, false);
    executarLeads(leadsCriar, saida, true);
    return saida;
  }

  private static void preencherRespostaCnhPorAnexo(List<Entrada> entradas) {
    Set<Id> sessoes = new Set<Id>();
    for (Entrada entrada : entradas) {
      if (entrada == null)
        continue;
      Id sessaoId = idDoTipo(entrada.routableId, MessagingSession.SObjectType);
      if (sessaoId != null)
        sessoes.add(sessaoId);
    }
    if (sessoes.isEmpty())
      return;

    Set<Id> sessoesComAnexo = new Set<Id>();
    if (Test.isRunningTest() && sessoesComAnexoTeste != null) {
      sessoesComAnexo.addAll(sessoesComAnexoTeste);
    } else {
      for (ContentDocumentLink vinculo : [
        SELECT LinkedEntityId
        FROM ContentDocumentLink
        WHERE LinkedEntityId IN :sessoes
      ]) {
        sessoesComAnexo.add(vinculo.LinkedEntityId);
      }
    }

    for (Entrada entrada : entradas) {
      if (entrada == null)
        continue;
      Id sessaoId = idDoTipo(entrada.routableId, MessagingSession.SObjectType);
      if (sessaoId != null && sessoesComAnexo.contains(sessaoId)) {
        entrada.respostaCNH = 'Vou enviar agora';
      }
    }
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

  private static void aplicar(Contact c, Entrada entrada) {
    c.STE_Interesse_Pre_Inscricao__c = interesse(entrada.respostaPreInscricao);
    c.STE_Faixa_Etaria__c = faixa(entrada.respostaIdade);
    c.STE_Ja_Trabalhou_Telecom__c = simNao(entrada.jaTrabalhouTelecom);
    c.STE_Empresa_Telecom_Anterior__c = empresa(entrada);
    c.STE_Possui_CNH__c = posseCnh(entrada.respostaCNH);
    c.STE_Classificacao_Fila__c = classificacao(entrada);
    c.STE_MessagingSession_Id__c = sessao(entrada);
  }

  private static void aplicar(Lead l, Entrada entrada) {
    l.STE_Interesse_Pre_Inscricao__c = interesse(entrada.respostaPreInscricao);
    l.STE_Faixa_Etaria__c = faixa(entrada.respostaIdade);
    l.STE_Ja_Trabalhou_Telecom__c = simNao(entrada.jaTrabalhouTelecom);
    l.STE_Empresa_Telecom_Anterior__c = empresa(entrada);
    l.STE_Possui_CNH__c = posseCnh(entrada.respostaCNH);
    l.STE_Classificacao_Fila__c = classificacao(entrada);
    l.STE_MessagingSession_Id__c = sessao(entrada);
    l.STE_Prazo_Envio_CNH__c = l.STE_Possui_CNH__c == 'Sim, envio posterior'
      ? System.now().addHours(2)
      : null;
    l.Status = l.STE_Faixa_Etaria__c == 'Fora da faixa'
      ? 'Desqualificado'
      : 'Validação';
  }

  private static void executarContatos(
    List<OperacaoContato> operacoes,
    List<Resultado> saida
  ) {
    if (operacoes.isEmpty())
      return;
    List<Contact> registros = new List<Contact>();
    for (OperacaoContato op : operacoes)
      registros.add(op.registro);
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
      registros.add(op.registro);
    Database.SaveResult[] resultados = inserir
      ? Database.insert(registros, false)
      : Database.update(registros, false);
    for (Integer i = 0; i < resultados.size(); i++) {
      concluir(saida[operacoes[i].indice], resultados[i], 'Lead');
    }
  }

  private static void concluir(
    Resultado saida,
    Database.SaveResult resultado,
    String tipo
  ) {
    saida.sucesso = resultado.isSuccess();
    saida.tipoRegistro = tipo;
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