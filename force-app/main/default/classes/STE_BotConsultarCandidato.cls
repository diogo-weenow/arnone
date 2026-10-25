/**
 * Busca o cadastro do candidato pelo WhatsApp da conversa, para o assistente
 * confirmar os dados antes de refazer as perguntas do formulário.
 *
 * A identificação usa a mesma ordem de STE_BotRegistrarCandidato, só que sem
 * e-mail: no começo da conversa ainda não perguntamos nada, o único dado que
 * temos é o telefone de onde a pessoa está falando.
 *   1. vínculo do telefone  — MessagingEndUser.ContactId, depois .LeadId
 *   2. telefone             — STE_Telefone_E164__c, com e sem nono dígito
 *   3. nada                 — devolve encontrado = false
 *
 * Só olha Lead não convertido: Lead convertido já virou Contato, e é o Contato
 * que o passo 1 acha. Entre vários candidatos pelo mesmo telefone, vence o
 * alterado por último, que é o que a pessoa mexeu mais recentemente.
 *
 * Esta ação não grava nada. A correção dos campos é feita por
 * STE_BotAtualizarCampo, chamada depois, só no campo que a pessoa escolheu.
 */
public without sharing class STE_BotConsultarCandidato {
  private static final String SEM_VALOR = 'não informado';

  public class Entrada {
    @InvocableVariable(label='Id do usuário final de mensageria')
    public String endUserId;
  }

  public class Resultado {
    @InvocableVariable(label='Cadastro encontrado')
    public Boolean encontrado;

    /**
     * Verdadeiro quando dá para seguir pela confirmação. Cadastro sem e-mail
     * fica de fora: STE_BotRegistrarCandidato precisa do e-mail no fim do
     * fluxo, e quem confirmasse dados sem ele chegaria lá para não ser
     * registrado. Esse candidato segue pelo caminho de sempre, que pede o
     * e-mail — e não repete o nome, que a consulta já preencheu.
     */
    @InvocableVariable(label='Dá para confirmar os dados')
    public Boolean podeConfirmar;

    @InvocableVariable(label='Id do registro')
    public String recordId;

    @InvocableVariable(label='Tipo do registro')
    public String tipoRegistro;

    @InvocableVariable(label='Nome completo')
    public String nome;

    @InvocableVariable(label='E-mail')
    public String email;

    @InvocableVariable(label='Telefone de contato')
    public String telefone;

    @InvocableVariable(label='Gênero')
    public String genero;

    /** Texto pronto para o assistente mostrar na confirmação. */
    @InvocableVariable(label='Resumo dos dados')
    public String resumo;

    private Resultado() {
      encontrado = false;
      podeConfirmar = false;
      resumo = '';
    }
  }

  @InvocableMethod(
    label='Consultar candidato do bot — Stech Telecom'
    description='Procura o Lead ou Contato do candidato pelo telefone da conversa e devolve os dados do formulário para confirmação.'
    category='Stech Telecom'
  )
  public static List<Resultado> consultar(List<Entrada> entradas) {
    List<Resultado> saida = new List<Resultado>();
    if (entradas == null || entradas.isEmpty()) {
      return saida;
    }

    Set<Id> ids = new Set<Id>();
    for (Entrada entrada : entradas) {
      saida.add(new Resultado());
      Id endUser = idDoTipo(
        entrada == null ? null : entrada.endUserId,
        MessagingEndUser.SObjectType
      );
      if (endUser != null) {
        ids.add(endUser);
      }
    }
    if (ids.isEmpty()) {
      return saida;
    }

    Map<Id, MessagingEndUser> endUsers = new Map<Id, MessagingEndUser>(
      [
        SELECT Id, LeadId, ContactId, MessagingPlatformKey
        FROM MessagingEndUser
        WHERE Id IN :ids
      ]
    );

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
          Name,
          Email,
          MobilePhone,
          STE_Genero__c,
          STE_Telefone_E164__c
        FROM Contact
        WHERE Id IN :contatosVinculados OR STE_Telefone_E164__c IN :telefones
        ORDER BY LastModifiedDate DESC
      ]
    );

    Map<Id, Lead> leads = new Map<Id, Lead>(
      [
        SELECT
          Id,
          Name,
          Email,
          MobilePhone,
          STE_Genero__c,
          STE_Telefone_E164__c
        FROM Lead
        WHERE
          IsConverted = FALSE
          AND (Id IN :leadsVinculados
          OR STE_Telefone_E164__c IN :telefones)
        ORDER BY LastModifiedDate DESC
      ]
    );

    Map<String, Contact> contatoPorTelefone = new Map<String, Contact>();
    for (Contact c : contatos.values()) {
      for (String variante : STE_Telefone.variantes(c.STE_Telefone_E164__c)) {
        if (!contatoPorTelefone.containsKey(variante))
          contatoPorTelefone.put(variante, c);
      }
    }

    Map<String, Lead> leadPorTelefone = new Map<String, Lead>();
    for (Lead l : leads.values()) {
      for (String variante : STE_Telefone.variantes(l.STE_Telefone_E164__c)) {
        if (!leadPorTelefone.containsKey(variante))
          leadPorTelefone.put(variante, l);
      }
    }

    for (Integer i = 0; i < entradas.size(); i++) {
      Id endUserId = idDoTipo(
        entradas[i] == null ? null : entradas[i].endUserId,
        MessagingEndUser.SObjectType
      );
      MessagingEndUser eu = endUserId == null
        ? null
        : endUsers.get(endUserId);
      if (eu == null) {
        continue;
      }

      if (contatos.containsKey(eu.ContactId)) {
        preencher(saida[i], contatos.get(eu.ContactId));
        continue;
      }
      if (leads.containsKey(eu.LeadId)) {
        preencher(saida[i], leads.get(eu.LeadId));
        continue;
      }

      String chave = primeiraVariante(
        eu.MessagingPlatformKey,
        contatoPorTelefone.keySet()
      );
      if (chave != null) {
        preencher(saida[i], contatoPorTelefone.get(chave));
        continue;
      }
      chave = primeiraVariante(
        eu.MessagingPlatformKey,
        leadPorTelefone.keySet()
      );
      if (chave != null) {
        preencher(saida[i], leadPorTelefone.get(chave));
      }
    }

    return saida;
  }

  private static void preencher(Resultado r, Contact c) {
    preencher(
      r,
      'Contact',
      c.Id,
      c.Name,
      c.Email,
      telefoneExibido(c.MobilePhone, c.STE_Telefone_E164__c),
      c.STE_Genero__c
    );
  }

  private static void preencher(Resultado r, Lead l) {
    preencher(
      r,
      'Lead',
      l.Id,
      l.Name,
      l.Email,
      telefoneExibido(l.MobilePhone, l.STE_Telefone_E164__c),
      l.STE_Genero__c
    );
  }

  private static void preencher(
    Resultado r,
    String tipo,
    Id registro,
    String nome,
    String email,
    String telefone,
    String genero
  ) {
    r.encontrado = true;
    r.tipoRegistro = tipo;
    r.podeConfirmar = !String.isBlank(email);
    r.recordId = String.valueOf(registro);
    r.nome = texto(nome);
    r.email = texto(email);
    r.telefone = texto(telefone);
    r.genero = texto(genero);
    r.resumo =
      '*Nome:* ' +
      ou(r.nome) +
      '\n*E-mail:* ' +
      ou(r.email) +
      '\n*Telefone:* ' +
      ou(r.telefone) +
      '\n*Gênero:* ' +
      ou(r.genero);
  }

  /**
   * Telefone que a pessoa vê. Prefere o MobilePhone, que é o que ela declarou;
   * cai para o número do WhatsApp quando o cadastro não tem telefone de
   * contato, para a confirmação não mostrar um campo vazio sem necessidade.
   */
  private static String telefoneExibido(String mobile, String e164) {
    String declarado = texto(mobile);
    if (declarado != null)
      return declarado;
    String chave = texto(e164);
    return chave == null ? null : '+' + chave;
  }

  private static String ou(String valor) {
    return valor == null ? SEM_VALOR : valor;
  }

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

  private static String texto(String valor) {
    return String.isBlank(valor) ? null : valor.trim();
  }
}