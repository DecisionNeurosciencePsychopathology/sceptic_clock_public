%This script creates a master lookup table for each condition (IEV, DEV, QUADUP, IEVLINPROB, DEVLINPROB).
%The rows represent time steps (10ms bins) and the columns represent successive draws from the contingency.
%NOTE: the TD agents sample at 100ms intervals I believe so when
%sampling occurs be sure to reduce (or remap) the master table so it can
%sample properly. Is this inherently a hinderence on the Q models???

%The idea is to have the same series of outcomes for an agent who samples the same RTs.
%So if SKEPTIC chooses 3500ms 4 times and Q-learning chooses 3500ms 4 times, both receive the same series
%of outcomes. This eliminates this source of variability in the costs.

addpath('../');

ntimesteps = 500; %in 10ms bins (1-5s)
conds = {'IEV' 'DEV' 'CEV' 'CEVR' 'QUADUP' 'QUADUPOLD' 'QUADDOWN', 'IEVLINPROB' 'DEVLINPROB'};
ntrials = 500; %number of draws for each RT where each draw becomes a column in the lookup matrix

%set up seeds
%global rew_rng_state;
%rew_rng_seed=71; %seed used to populate outcomes 
%rng(rew_rng_seed);
%rew_rng_state=rng;

mastersamp=[];
for i = 1:length(conds)
    %Initalize structure
    mastersamp.(conds{i}).lookup = zeros(ntimesteps,ntrials); %lookup table of timesteps and outcomes
    mastersamp.(conds{i}).sample = zeros(1,ntimesteps); %keeps track of how many times a timestep has been sampled by agent
    mastersamp.(conds{i}).ev = zeros(1,ntimesteps);
    
    for j = 1:ntimesteps
        [~, mastersamp.(conds{i}).ev(j), mastersamp.(conds{i}).prb(j), mastersamp.(conds{i}).mag(j)] = RewFunction(j*10, conds{i}, 0, 5000);
        for k = 1:ntrials %draw random samples
            [mastersamp.(conds{i}).lookup(j,k)] = RewFunction(j*10, conds{i}, 0, 5000);
        end
    end
    
    %parsave(['mastersamp_' conds{i} '.mat'], mastersamp);
end
save('mastersamp.mat', 'mastersamp');

%renormalize Frank contingencies to have identical EV to weight equally in optimization
%just use the 4 core IEV, DEV, CEV, CEVR for now
%use IEV as the reference and rescale magnitudes

mastersamp_equateauc = mastersamp;
conds_to_normalize = fieldnames(mastersamp_equateauc);
iev_ev_auc = sum(mastersamp_equateauc.IEV.ev);
for i = 1:length(conds_to_normalize)
   cond_ev_auc = sum(mastersamp_equateauc.(conds_to_normalize{i}).ev);
   renorm = iev_ev_auc/cond_ev_auc;
   %multiply draws by renormalization constant
   mastersamp_equateauc.(conds_to_normalize{i}).ev = mastersamp_equateauc.(conds_to_normalize{i}).ev * renorm;
   mastersamp_equateauc.(conds_to_normalize{i}).mag = mastersamp_equateauc.(conds_to_normalize{i}).mag * renorm;
   mastersamp_equateauc.(conds_to_normalize{i}).lookup = mastersamp_equateauc.(conds_to_normalize{i}).lookup * renorm;
end

%plot(mastersamp.DEV.mag.*mastersamp_equateauc.DEV.prb)
%xx1 = mastersamp.DEV.mag.*mastersamp_equateauc.DEV.prb;
%xx2 = mastersamp_equateauc.DEV.mag.*mastersamp_equateauc.DEV.prb;

save('mastersamp_equateauc.mat', 'mastersamp_equateauc');

%New approach: generate variants of time-varying contingencies that do not prefer sampling at the edge.
%Use sinusoidal functions to generate a continuous contingency that can be shifted in time to maintain a constant EV AUC (identical costs)
%while shifting the optimal RT. Then optimize a subset of these possible contingencies (sampled at random)

ntimesteps=500;

ev = 10*sin(2*pi*(1:ntimesteps).*1/ntimesteps) + 2.5*sin(2*pi*(1:ntimesteps)*2/ntimesteps) + 2.0*cos(2*pi*(1:ntimesteps)*4/ntimesteps);
ev = ev + abs(min(ev)) + 10;
prb = 25*cos(2*pi*(1:ntimesteps).*1/ntimesteps) + 10*cos(2*pi*(1:ntimesteps)*3/ntimesteps) + 6*sin(2*pi*(1:ntimesteps)*5/ntimesteps);
prb_max=0.7;
prb_min=0.3;
prb = (prb - min(prb))*(prb_max-prb_min)/(max(prb)-min(prb)) + prb_min;

%simpler version without substantial high-frequency oscillation
% ev = 10*sin(2*pi*(1:ntimesteps).*1/ntimesteps) + 2.5*sin(2*pi*(1:ntimesteps)*2/ntimesteps);
% ev = ev + abs(min(ev)) + 10;
% prb = 25*cos(2*pi*(300-(1:ntimesteps)).*1/ntimesteps); %+ 10*cos(2*pi*(1:ntimesteps)*3/ntimesteps);
% prb_max=0.7;
% prb_min=0.3;
% prb = (prb - min(prb))*(prb_max-prb_min)/(max(prb)-min(prb)) + prb_min;

%mag = mag + abs(min(mag)) + 10;
%prb = evi./magi;
%plot(1:ntimesteps, mot1, type="l")

%figure(1); clf;
allshift = NaN(ntimesteps, ntimesteps, 3);
conds = 1:ntimesteps;
for i = 1:ntimesteps
  shift=[i:ntimesteps 1:(i-1)];
  evi = ev(shift);
  prbi = prb(shift);
  
  allshift(i,:,1) = evi;
  allshift(i,:,2) = prbi;
  allshift(i,:,3) = evi./prbi;
  
  %subplot(3,1,1); plot(1:ntimesteps, evi)
  %subplot(3,1,2); plot(1:ntimesteps, prbi);
  %subplot(3,1,3); plot(1:ntimesteps, evi./prbi);
  %pause(0.02)
  
end

rng(102); %fix seed for pulling reward probabilities
ntrials = 500; %maximum number of trials that could be used for testing this contingency

%randomly sample 60 of the possible 500 contingencies without replacement
keep = randsample(1:ntimesteps, 60);

%for consistency with prior simulations, keep sinusoid 366 as first variant (this is roughly quad down with max at 250 and prb max at 150)
keep(1) = 366;

optmat=cell(1,1);
for k = 1:length(keep)
    thisCont=[];
    thisCont.name = ['sinusoid' num2str(keep(k))];
    thisCont.sample = zeros(1, ntimesteps); %keeps track of how many times a timestep has been sampled by agent
    thisCont.lookup = zeros(ntimesteps, ntrials); %lookup table of timesteps and outcomes
    thisCont.ev = allshift(keep(k),:,1);
    thisCont.prb = allshift(keep(k),:,2);
    thisCont.mag = allshift(keep(k),:,3);
    
    rvec = rand(ntimesteps, ntrials);
    for t = 1:ntrials
        thisCont.lookup(:,t) = (allshift(keep(k),:,2) > rvec(:,t)') .* allshift(keep(k),:,3);
    end
    
    optmat{1}(k) = thisCont;
end

save('sinusoid_optmat.mat', 'optmat');


%Double parabola with a fluctuating base
%move the parabola positions randomly, but don't overlap
rng(456);
nreps=100;
bumpsd = 15;
ntimesteps=500;
bump1mag = 100;
bump2mag = bump1mag/2;
cliffpullback = 2*bumpsd;
bumpset = NaN(nreps, ntimesteps);
prew=0.7; %always 70/30 for bumps

%normalize the noisefloor to have exactly the same AUC so that its influence on AUC of contingency is fixed (for equal run optimization)
noiseref=NaN;
allbumps=NaN(nreps, ntimesteps, 3);
for i = 1:nreps
    bumpokay = false;
    while ~bumpokay
        bump1 = randi([cliffpullback, ntimesteps-cliffpullback]);
        bump2 = randi([cliffpullback, ntimesteps-cliffpullback]);
        if abs(bump1 - bump2) > 5*bumpsd %bumps 5 SDs apart to enforce essential non-overlap
            bumpokay = true;
        end
    end
    
    bump1func = gaussmf(1:ntimesteps, [bumpsd bump1]).*bump1mag;
    bump2func = gaussmf(1:ntimesteps, [bumpsd bump2]).*bump2mag;
    
    noisefloor = smooth(exprnd(bump1mag/10, 1, ntimesteps), 20, 'lowess')';
    noisefloor(bump1func > quantile(noisefloor, .25) | bump2func > quantile(noisefloor, .25)) = 0;
    if i == 1, noiseref = sum(noisefloor); end
    noisefloor = noisefloor./sum(noisefloor).*noiseref; %this nearly perfectly normalizes the AUC, except when bumps are near the edge
    
    func = noisefloor + bump1func + bump2func;
    bumpset(i, :) = func;
    if i == 1, pause; end
    plot(func);
    pause(0.3);
    allbumps(i,:,1) = func;
    allbumps(i,:,2) = repmat(prew, 1, ntimesteps);
    allbumps(i,:,3) = allbumps(i,:,1).*allbumps(i,:,2);
end

keep = randsample(1:nreps, 60);
ntrials = 500; %maximum number of trials that could be used for testing this contingency

optmat=cell(1,1);
for k = 1:length(keep)
    thisCont=[];
    thisCont.name = ['doublebump' num2str(keep(k))];
    thisCont.sample = zeros(1, ntimesteps); %keeps track of how many times a timestep has been sampled by agent
    thisCont.lookup = zeros(ntimesteps, ntrials); %lookup table of timesteps and outcomes
    thisCont.ev = allbumps(keep(k),:,1);
    thisCont.prb = allbumps(keep(k),:,2);
    thisCont.mag = allbumps(keep(k),:,3);
    
    rvec = rand(ntimesteps, ntrials);
    for t = 1:ntrials
        thisCont.lookup(:,t) = (allbumps(keep(k),:,2) > rvec(:,t)') .* allbumps(keep(k),:,3);
    end
    
    optmat{1}(k) = thisCont;
end

save('doublebump_optmat.mat', 'optmat');